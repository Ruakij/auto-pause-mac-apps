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
| `resumeTree(root:keepStopped:)` | `SIGCONT` children first, parent last, skipping the subtrees in `keepStopped` | Reverse order so the parent finds its children already alive. Resuming a whole app leaves its separately frozen windows frozen. |
| `children(of:)` | Direct children via `proc_listchildpids` | A VS Code window opening or closing changes the main process's children, which invalidates the cached window mapping. |
| `cpuTimeNanos(of:)` | User + system CPU from `proc_pid_rusage`, mach ticks converted to ns | The one CPU sampler, shared by busy detection and the expanded rows. |
| `startTime(of:)` | `pbi_start_tvsec`/`usec` from `PROC_PIDTBSDINFO` | Pairs a helper pid with its start time in window records, as `launchDate` does for apps. |
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

- **Auto-pause** - one one-shot `Timer` per app with auto-pause enabled, due at
  `lastFrontDate` + its minutes, on the main run loop in common modes so it fires with the
  panel closed. `lastFrontDate` is set when the app is deactivated (and when it is resumed).
  Timers are rebuilt by `rescheduleAutoPause()` on start, app launch and termination, wake from
  sleep (one-shot timers do not advance while the Mac sleeps), and when a per-app setting
  changes; activation cancels the app's timer, deactivation arms it. Only `.regular` apps that
  are not frontmost (the pid from the last activation notification, not `isActive`, which can
  still read true right after deactivation) are armed or frozen. On fire, `BusyEvaluator`
  checks the system-wide blockers and the app's busy findings off the main thread. If the app
  has no recent CPU sample, it is only sampled and checked again in 30 s, so CPU is judged over
  those 30 s. If a blocker or finding remains, the app is checked again in 60 s without
  touching its idle clock, otherwise it is frozen and recorded in `PausedStore`. If the app was
  activated, rescheduled or frozen while the check ran, the result is dropped.
- **Busy checks for the UI** - `busyFindings(for:)` for one row or for all Free Up Memory
  candidates in one pass. `BusyGate` (in `MenuView.swift`) runs the check for the row buttons
  and the detail popover's Pause Now: a busy result arms Force for 5 s; clicks during a check
  and results arriving after the pointer left are ignored. `busySettings` (global, `UserDefaults`) is saved on every change.
- **Thaw on activation** — when `didActivateApplicationNotification` names a frozen pid (in
  `PausedStore` or stopped), the whole tree is resumed, its record dropped, its idle clock
  reset and the pid removed from `reclaimSession`. This covers every frozen app, whether
  auto-paused, paused by hand or by Free Up Memory. The notification arrives while the app is
  still stopped; requests that go through the app itself (`NSRunningApplication.activate()`,
  `osascript ... activate`) produce no notification and are lost.

- **Expanded rows** - `toggleExpanded(_:)`; on each refresh every expanded app gets an
  `AppDetail`: its tree in tree order (`AppProcesses.list`) with resident memory and CPU % from
  the delta to the previous refresh. With a window mapping or window records it is split into
  `WindowDetail`s (live trees of each group's anchors) and the shared rest. A window frozen while
  missing from the mapping is still listed from its records.
- **Window mappings** - cached per app pid (`WindowGroups.mapping`, run in a detached task:
  `code --status` takes seconds). Fetched again when the row is expanded, a window timer fires or
  a focused window matches no group, if the cache is older than 30 s or the app's direct
  children changed. Direct children rather than the whole tree: extension hosts spawn and reap
  commands constantly, which would refetch on every refresh.
- **Window freeze** - `pauseWindow` / `freezeWindow` run `pauseTree` on each anchor of the group
  (renderer, extension host, file watcher) that is still a direct child of the app and not
  shared, and record each as a window record. `resumeWindow` resumes the live ones and drops the
  records. Before a freeze the app's AX window titles are read (the main process is not
  frozen, so this is fast) and the one equal to the group's mapping title is stored as
  `windowTitle`; when none is, the mapping is fetched again first (the manual Pause shows
  "Checking..." meanwhile). A frozen renderer cannot retitle its window, so this is the title
  any later focus or click reports. No window is frozen while its app is frozen whole. Resume
  All and quit resume window records before app records (children first), and only records
  whose pid still has the recorded start time. Deep Sleep first resumes the app's frozen
  windows, which could not handle the quit.
- **Quit with frozen windows** - an app with a frozen window cannot quit: its main process
  waits for the frozen renderer's unload reply (observed with VS Code, single and multi
  window). No public notification reports another app starting to quit, so: the unfrozen
  renderers of such an app get a `DispatchSource` exit watcher (`syncExitWatchers`; in a quit
  they exit within a second) and any exit resumes all the app's frozen windows; Cmd-Q while the
  app is frontmost does the same (global key monitor); `willPowerOffNotification` resumes every
  window record. Quitting a single-window app from its menu or the Dock is not detected.
- **Window focus** - a `WindowFocusObserver` runs for every app with window records or
  per-window auto-pause, when Accessibility is trusted. A focus change matched to a frozen
  window (`WindowGroups.match` against the record titles) resumes it; a title that matches no
  record is placed through the mapping (fetched again when the cached one does not place it)
  and compared by window id. On activation the focused window is read once after 300 ms,
  because a click into the window that was already focused changes no focus. While any window
  is frozen a global mouse-down monitor hit-tests clicks in the frontmost app
  (`AXUIElementCopyElementAtPosition`, window frames as fallback), for a click back into a
  window frozen while it was focused. Thaw on activation leaves window records frozen
  (`keepStopped`). No observer is created for a stopped app, AX calls time out after 0.25 s,
  and a failed observer is retried only after 60 s, on app launch or quit, or when
  Accessibility trust changes.
- **Per-window auto-pause** - for VS Code-family apps with auto-pause on and Accessibility
  trusted (`usesWindowAutoPause`); such apps are never auto-frozen whole. One one-shot timer per
  window (`windowTimers`, same style as the app timers) at `windowIdleSince` + the app's
  minutes. `windowIdleSince` is set when a window stops being the focused window of the
  frontmost app (focus moves away, the app deactivates, the window is resumed) or when it is
  first seen. On fire: fresh mapping, skip the focused window of the frontmost app (an
  unidentifiable focused window counts as it), system blockers, busy findings over the group's
  pids with the same 30 s and 60 s retries as apps, then `freezeWindow`. An app frozen whole
  has no window timers: they are cancelled when it is paused and re-armed when it resumes.
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

## `BusyDetector.swift`, `BusySettings.swift` - busy conditions

`BusyDetector` evaluates the enabled conditions over a set of process trees: CPU (rusage delta
in mach ticks, summed over the tree), audio (Core Audio process objects), power assertions
(`IOPMCopyAssertionsByProcess`, on-behalf-of pid), debugger (`PROC_FLAG_TRACED`), devices (open
`/dev/cu.*`, `/dev/tty.*`, `/dev/disk*` and `IOHIDLibUserClient` creators), input taps
(`CGGetEventTapList`: an enabled tap that is not listen-only) and processes (regexes on the full
command line from `KERN_PROCARGS2`). `findings(forTrees:)` reads the system-wide lists once for
all trees. It keeps the previous CPU sample per pid (dropped after 120 s); for manual checks a pid
without one gets a first sample and a single 200 ms wait. Auto-pause passes
`waitForCPU: false`: a tree with no sample at all gets a nil result (sampled, no verdict), and
pids new to an already sampled tree are skipped for CPU until the next check. `systemBlockers()` reports camera in use,
`screensharingd` and `SidecarRelay`, which block every automatic pause.

The detector is stateful and not thread-safe, and the CPU wait would stall the UI, so
`BusyEvaluator` owns it on one serial dispatch queue and returns results through `async`
functions. `BusySettings` holds the conditions, CPU threshold and regex list in `UserDefaults`, each
falling back to its default on its own. Conditions are stored as the disabled set, so one added
later starts enabled.

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
| `paused.json` | `PausedStore.swift` | Frozen apps and window groups. A whole-app record has no `ownerPid`; a window record holds one group anchor with `ownerPid`, `windowId`, `windowTitle`, and the anchor's start time in `launchDate`. Pid reuse is guarded by launch date / start time. A window record whose anchor is no longer a child of its owner (the app quit) is resumed and dropped. New fields decode with defaults, so older files stay readable. If Pause is killed, frozen apps are still recognised on next launch. |
| `slept.json` | `SleptStore.swift` | Deep-slept apps. **Essential** — a slept app is gone from `runningApplications`, so without this record it would disappear and be unrecoverable. |
| `settings.json` | `AppSettingsStore.swift` | Per-app idle auto-pause (on/off, minutes), keyed by bundle ID. |

---

## Views

| File | Role |
|---|---|
| `AppProcesses.swift`, `WindowGroups.swift`, `WindowFocusObserver.swift` | Process tree with role labels; VS Code window mapping (`code --status`, env/fd fallback) and AX title matching; Accessibility trust, prompt, settings link and the focus observer. |
| `MenuView.swift` | The panel: ring gauge, system usage graph, and the list in two sections: SUSPENDED and APPS. A row's Pause and Deep Sleep buttons check the app for busy findings first; if busy, the memory line shows them and the clicked button turns into an orange Force for 5 s or until the pointer leaves the row (for Deep Sleep this comes before the first-time warning). The list gets an explicit height computed from the row and section counts, capped at the screen height (a `ScrollView` has no intrinsic size, so without an explicit height the window collapses; computing rather than measuring keeps the size stable across refreshes; expanded rows add their line count times a fixed line height). Each row has a chevron that expands it into its processes, or into window sections with Pause/Resume (through their own `BusyGate` over the window's pids; disabled with a tooltip without Accessibility) and a Shared section. Settings shows the Accessibility state with a button to System Settings. |
| `DetailViews.swift` | `SparklineView`, `UsageAreaChart` (plotted against total RAM so normal fluctuation looks normal, not like a mountain range), and the per-app detail popover with auto-pause settings. |
| `SystemDetailView.swift` | Ring gauge, usage history, App/Wired/Compressed/Free/Swap breakdown, top processes. |
| `ReclaimView.swift` | Free Up Memory: a reviewable checklist of what will be paused, with running totals, before anything happens. Busy apps (checked in one pass on open; the confirm button waits for it) start unticked with the reason as subtitle, and are never remembered as opt-outs. Recording and call apps start unticked. Opt-outs can be remembered. |
| `BusySettingsView.swift` | Settings > Busy apps, a page inside the Settings popover: one checkbox per condition, CPU threshold, and the editable regex list (invalid entries are marked and not saved). |
| `DeepSleepWarningView.swift` | First-run warning: explains Deep Sleep actually quits the app, reports that app's restore status, offers to enable window restore. |
| `PauseApp.swift` | `MenuBarExtra` host plus the `NSApplicationDelegate`. Presents the first-run walkthrough in a real `NSWindow` (an `LSUIElement` app isn't activated by default, so it calls `NSApp.activate` explicitly), and resumes every frozen app and window on quit so nothing is ever stranded. Asks for Accessibility at launch when not trusted (the system shows its prompt at most once). |
| `OnboardingView.swift` | Four-page animated walkthrough: welcome, the two tiers, Free Up Memory, and where to find the app + start-at-login. Exists because a menu-bar-only app with no Dock icon is easy to lose immediately after installing. |
| `LaunchAtLogin.swift` | `SMAppService.mainApp` wrapper. Registration is idempotent (registering when already enabled throws), and the status is read back afterwards — `register()` can succeed while the item still needs approval, or not take effect when the app runs from a DMG or build folder. |

> **Naming note.** The product is *Auto Pause Mac Apps*; the SwiftPM target and binary are
> `AutoPauseMacApps`. The Application Support directory deliberately remains `Pause/` — renaming
> it would orphan existing records and strand apps that users currently have frozen.
