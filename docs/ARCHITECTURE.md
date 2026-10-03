# Auto Pause Mac Apps — Architecture, module by module

Auto Pause Mac Apps is a single SwiftUI menu-bar executable built with Swift Package
Manager. No Xcode project, no external dependencies, no bundled frameworks. Every module
below is one file in `Sources/AutoPauseMacApps/`.

```
┌──────────────────────────────────────────────────────────────┐
│  PauseApp.swift          MenuBarExtra host + quit safety net  │
└───────────────┬──────────────────────────────────────────────┘
                │ observes
┌───────────────▼──────────────────────────────────────────────┐
│  AppListModel.swift      the single source of truth           │
│    · merges running apps + sleeping records into one list     │
│    · owns history sampling, auto-pause, Local Model Mode      │
└──┬────────────┬───────────────┬──────────────┬───────────────┘
   │            │               │              │
┌──▼─────────┐ ┌▼────────────┐ ┌▼───────────┐ ┌▼──────────────┐
│ Process    │ │ DeepSleep   │ │ SystemStats│ │ Stores        │
│ Control    │ │ Controller  │ │            │ │ Paused/Slept/ │
│ signals    │ │ quit+restore│ │ vm stats   │ │ AppSettings   │
└────────────┘ └─────────────┘ └────────────┘ └───────────────┘
                          ▲
┌─────────────────────────┴────────────────────────────────────┐
│  Views: MenuView · DetailViews · SystemDetailView             │
│         ReclaimView · DeepSleepWarningView                    │
└──────────────────────────────────────────────────────────────┘
```

---

## `ProcessControl.swift` — the kernel-facing layer

Everything that talks to the OS about processes. No UI, no state; pure functions.

| Function | What it does | Why it matters |
|---|---|---|
| `processTree(root:)` | Breadth-first walk via `proc_listchildpids`, returns the app plus every descendant | Chrome's memory lives in ~25 helper processes. Signalling only the parent would free almost nothing. |
| `memoryInfo(of:)` | One `proc_pid_rusage` call returning **both** `ri_resident_size` and `ri_phys_footprint` | The two numbers diverge enormously (Chrome: 275 MB vs 4.31 GB). Reporting only footprint made pausing look broken. |
| `treeMemory(root:)` | Sums `MemoryInfo` across the tree | An app's real cost is the whole tree. |
| `pauseTree(root:)` | `SIGSTOP` **parent first**, then descendants | Parent-first stops it spawning new children mid-freeze, which would escape the sweep. |
| `resumeTree(root:)` | `SIGCONT` children first, parent last | Reverse order so the parent finds its children already alive. |
| `isStopped(_:)` | Reads `pbi_status == SSTOP` | Ground truth. Detects apps frozen outside Pause, and survives Pause restarting. |
| `treeContainsSelf(root:)` | Checks whether a tree contains this process, walking both descendants and our own ancestry | `pauseTree` refuses when true. Freezing ourselves is unrecoverable: the menu bar stops responding, so nothing can be resumed and everything frozen in the same sweep stays frozen. Enforced at the signal layer so it holds no matter what the caller asks for. |

> **Removed in 1.3:** system-wide daemon enumeration (`userProcesses`, a `protectedNames`
> deny-list). Listing and freezing background services could leave a Mac hard to operate, and a
> deny-list is the wrong shape for that risk — you cannot enumerate everything that matters.
> Auto Pause now only touches apps the user explicitly approves.

**Design note — why no entitlements.** Apple's guidance is to use `libproc` (`proc_pid_rusage`,
`proc_pidinfo`) rather than `task_for_pid()`, which is SIP-restricted to development tools.
Everything here works on same-user processes with no entitlement, no root, no TCC prompt.

---

## `DeepSleepController.swift` — the quit-and-restore tier

The only mechanism on macOS that frees **all** of an app's memory including swap.

- **`canRestoreState(bundleID:)`** — will this app bring its windows back?
  - Chromium browsers: reads `session.restore_on_startup` from the browser's own
    Preferences JSON (they ignore macOS Resume entirely).
  - Safari: reports that it uses its own "Safari opens with" setting.
  - Everything else: reads `NSQuitAlwaysKeepsWindows` from that app's preference domain.
  - Returns `.good` / `.fixable` / `.unknown`, which drives the warning sheet.
- **`enableStateRestoration(bundleID:)`** — writes `NSQuitAlwaysKeepsWindows` into that app's
  domain. Only ever called on explicit consent, and records what it changed so it can be reverted.
- **`sleep(app:…)`** — thaws the app if frozen (a `SIGSTOP`ped process can't process a quit
  Apple Event), then `terminate()` — a normal ⌘Q, **never** `forceTerminate`. Polls up to 10 s.
- **`watchForLateTermination`** — if the app was showing a save sheet and the user answers it
  minutes later, the app quits after we gave up. Without this watcher it would vanish from Pause
  with no way to wake it.
- **`wake(_:)`** — relaunches via `NSWorkspace.openApplication` with `activates = true`, and
  **only clears the record on success**. An earlier version cleared it unconditionally, so a
  failed relaunch erased the app from the UI permanently.

**Your work is never at risk.** Apps that autosave save and quit. Apps that don't show their
normal save sheet and stay open; Pause reports `.refused` and leaves them merely frozen.

---

## `AppListModel.swift` — state and policy

`@MainActor ObservableObject`, refreshed every 3 s while the panel is open.

- **Three states** per entry: `.running`, `.paused` (SIGSTOP), `.sleeping` (quit, resumable).
- **Apps only.** Entries come solely from `NSWorkspace.runningApplications` filtered to
  `.regular`, so daemons never enter the list.
- **`reclaimCandidates`** — apps Free Up Memory may *offer*. Excludes this app, the frontmost
  app, anything whose tree contains us, and anything the user opted out of.
- **`reclaim(selected:)`** — pauses exactly the apps the user ticked. No target-chasing and no
  extras; if `pauseTree` refuses one, it is reported rather than silently skipped. Records the
  pid set as a `reclaimSession`.
- **`restoreReclaimSession()`** — undoes precisely what that run froze, leaving anything you
  froze by hand still frozen.
- **Sort order** — suspended entries pin to the top. They hold 0 resident RAM, so sorting purely
  by memory buried them beneath every running app and made them hard to bring back.
- **History** — rolling 40 samples of *resident* memory per entry, feeding the sparklines.

---

## `SystemStats.swift` — machine-wide numbers

One `host_statistics64` call plus `sysctl vm.swapusage`, decomposed into App / Wired /
Compressed / Free / Swap. Drives the ring gauge, the usage graph and the breakdown bar.

Worth understanding: **"Memory Used" includes compressed pages.** On a heavily oversubscribed
Mac (e.g. 43 GB logical on 16 GB physical) freeing a page just lets macOS page an active app
back in, so the gauge stays near max even as Pause genuinely reclaims gigabytes. That is macOS
behaving correctly — and it's exactly why per-app *resident* memory is the honest metric.

---

## Persistence — three small stores

All atomic JSON in `~/Library/Application Support/Pause/` (path kept stable across the rename — see the naming note below).

| File | Module | Purpose |
|---|---|---|
| `paused.json` | `PausedStore.swift` | Frozen apps. Guards against pid reuse by matching launch dates. If Pause is killed, frozen apps are still recognised on next launch. |
| `slept.json` | `SleptStore.swift` | Deep-slept apps. **Essential** — a slept app is gone from `runningApplications`, so without this record it would disappear and be unrecoverable. |
| `settings.json` | `AppSettingsStore.swift` | Per-app idle auto-pause (on/off, minutes), keyed by bundle ID. |

---

## Views

| File | Role |
|---|---|
| `MenuView.swift` | The panel: ring gauge, system usage graph, and the list in two sections: SUSPENDED and APPS. The list gets an explicit height computed from the row and section counts, capped at the screen height (a `ScrollView` has no intrinsic size, so without an explicit height the window collapses; computing rather than measuring keeps the size stable across refreshes). |
| `DetailViews.swift` | `SparklineView`, `UsageAreaChart` (plotted against total RAM so normal fluctuation looks normal, not like a mountain range), and the per-app detail popover with auto-pause settings. |
| `SystemDetailView.swift` | Ring gauge, usage history, App/Wired/Compressed/Free/Swap breakdown, top processes. |
| `ReclaimView.swift` | Free Up Memory: a reviewable checklist of what will be paused, with running totals, before anything happens. Recording and call apps start unticked. Opt-outs can be remembered. |
| `DeepSleepWarningView.swift` | First-run warning: explains Deep Sleep actually quits the app, reports that app's restore status, offers to enable window restore. |
| `PauseApp.swift` | `MenuBarExtra` host plus the `NSApplicationDelegate`. Presents the first-run walkthrough in a real `NSWindow` (an `LSUIElement` app isn't activated by default, so it calls `NSApp.activate` explicitly), and resumes every frozen app on quit so nothing is ever stranded. |
| `OnboardingView.swift` | Four-page animated walkthrough: welcome, the two tiers, Free Up Memory, and where to find the app + start-at-login. Exists because a menu-bar-only app with no Dock icon is easy to lose immediately after installing. |
| `LaunchAtLogin.swift` | `SMAppService.mainApp` wrapper. Registration is idempotent (registering when already enabled throws), and the status is read back afterwards — `register()` can succeed while the item still needs approval, or not take effect when the app runs from a DMG or build folder. |

> **Naming note.** The product is *Auto Pause Mac Apps*; the SwiftPM target and binary are
> `AutoPauseMacApps`. The Application Support directory deliberately remains `Pause/` — renaming
> it would orphan existing records and strand apps that users currently have frozen.
