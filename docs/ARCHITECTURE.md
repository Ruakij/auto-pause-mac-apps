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
| `children(of:)` | Direct children via `proc_listchildpids`, growing the buffer as needed | The step of `processTree`. |
| `cpuTimeNanos(of:)` | User + system CPU from `proc_pid_rusage`, mach ticks converted to ns | The CPU sampler of busy detection. |
| `startTime(of:)` | `pbi_start_tvsec`/`usec` from `PROC_PIDTBSDINFO` | Pairs the pid of a window record (see Persistence) with its start time, as `launchDate` does for apps. |
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
normal save sheet and stay open; Pause reports `.refused`, leaves them running (never frozen, so
the sheet stays answerable) and posts "<name> did not quit (unsaved changes?) and stays open".

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
  has no CPU sample at least 20 s old, it is only sampled and checked again in 30 s, so CPU is
  judged over at least 20 s even while the panel's live pass samples every 3 s. If a blocker or finding remains, the app is checked again in 60 s without
  touching its idle clock, otherwise it is frozen and recorded in `PausedStore`. If the app was
  activated, rescheduled or frozen while the check ran, the result is dropped.
- **Live state** - while the panel is open, every refresh starts one `BusyEvaluator` pass (none
  while one still runs) over every listed app except never-freeze apps and frozen apps. CPU is
  measured since the previous pass, without the 200 ms wait, so a tree with no recent sample
  gets no state on the first pass. The result is `appStates` (`LiveState`): busy reasons ("in
  use" for the frontmost app, then the findings), the idle start (`lastFrontDate` or launch) and
  the auto-pause timer's fire date. Closing the panel clears it and drops a pass still running.
- **Busy checks for the UI** - `busyFindings(for:)` for one row or for all Free Up Memory
  candidates in one pass. `BusyGate` (in `MenuView.swift`) handles the row buttons and the
  detail popover's Pause by the state on screen: shown busy arms Force for 5 s with that
  text, shown idle acts at once, no state yet runs the check first. Clicks during a check and
  results arriving after the pointer left are ignored. The armed button is `GatedButton`, the one
  Force component of app rows and the detail popover. `busySettings` (global, `UserDefaults`) is saved on every change.
- **Never freeze** - `neverFreeze` (bundle IDs, `NeverFreezeList` in `BusySettings.swift`,
  `UserDefaults` key `PauseNeverFreezeBundleIDs`; absent = defaults, otherwise the full list so a
  removed default stays removed). Every freeze goes through `freeze(root:bundleID:)`: manual
  Pause, auto-pause and Free Up Memory. It refuses listed apps and the frontmost app
  (`frontPid`); there is no Force. Listed apps
  get no auto-pause timer (`scheduleAutoPause` checks the list before the setting and leaves
  the timer cancelled; a change to the list reschedules every app) and are not Free Up Memory
  candidates. Their stored auto-pause setting is kept, so removing an app from the list
  restores its auto-pause. Deep Sleep stays available. At launch,
  bundle IDs still flagged `excludedFromReclaim` in `settings.json` (an older Free Up Memory
  opt-out) are appended to the list and the flag cleared
  (`AppSettingsStore.takeExcludedFromReclaim`).
- **Thaw on activation** — when `didActivateApplicationNotification` names a frozen pid (in
  `PausedStore` or stopped), the whole tree is resumed, its record dropped, its idle clock
  reset and the pid removed from `reclaimSession`. This covers every frozen app, whether
  auto-paused, paused by hand or by Free Up Memory. The notification arrives while the app is
  still stopped; requests that go through the app itself (`NSRunningApplication.activate()`,
  `osascript ... activate`) produce no notification and are lost. Clicking the app that is
  already frontmost activates nothing either, which is why `freeze` refuses the frontmost app.
- **Frontmost app** - `frontPid` (`@Published`) is set by `didActivate` and cleared by
  `didDeactivate`, so rows re-render when the front app changes while the panel is open;
  `isFrontmost(_:)` is what `freeze` and the views check. The panel does not activate Auto
  Pause, so it reads the app in use before the panel opened; with the Settings window open it
  is Auto Pause itself and no listed app is refused.

- **Window records** - `paused.json` can hold window records (`ownerPid` set) from builds that
  froze single windows. Nothing else would ever wake them, so `resumeWindowRecords()` resumes
  each one whose pid still has the recorded start time and drops them all at launch, before the
  first refresh. A window of an app that is itself still frozen is only dropped: resuming the
  app resumes its whole tree. No code writes window records.
- **Three states** per entry: `.running`, `.paused` (SIGSTOP), `.sleeping` (quit, resumable).
- **Apps only.** Entries come solely from `NSWorkspace.runningApplications` filtered to
  `.regular`, so daemons never enter the list. Finder is listed (on the Never freeze list by
  default).
- **`reclaimCandidates`** — apps Free Up Memory may *offer*. Excludes this app, the frontmost
  app, never-freeze apps and anything whose tree contains us.
- **`reclaim(selected:)`** — pauses exactly the apps the user ticked. No target-chasing and no
  extras; if `pauseTree` refuses one, it is reported rather than silently skipped. Records the
  pid set as a `reclaimSession`.
- **`restoreReclaimSession()`** — undoes precisely what that run froze, leaving anything you
  froze by hand still frozen.
- **Notices** - `notice` (`Notice`: text, `isWarning`) is shown above the list until dismissed
  or replaced. Warnings: a manual Pause that `freeze` refuses (never-freeze, frontmost, or `pauseTree`
  refusing), a failed wake (also from Wake all), Deep Sleep
  refused or failed, Free Up Memory pausing nothing or skipping apps. Confirmations: Free Up
  Memory ("Paused N apps, up to X reclaimable") and its Restore.
- **Wake** - `waking` holds the bundle IDs whose relaunch runs; the row shows "Waking..." and
  ignores further clicks meanwhile.
- **Sort order** - paused and deep-slept entries pin to the top. They hold 0 resident RAM, so sorting purely
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
all trees. It keeps every CPU sample per pid for 120 s, and each call adds one; a call measures
against the newest earlier sample at least `minCPUWindow` old, so the panel's 3 s live pass
(window 0) and auto-pause (window 20 s) share samples without shortening the auto-pause window.
For manual checks a pid without any sample gets a first one and a single 200 ms wait. Auto-pause
and the live pass pass `waitForCPU: false`: a tree with no usable baseline for any pid gets a
nil result (sampled, no verdict), and pids without one in an otherwise measured tree are
skipped for CPU until the next check. `systemBlockers()` reports camera in use,
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
`pressureLevel` is the kernel pressure level from `sysctl kern.memorystatus_vm_pressure_level`
(1 normal, 2 warning, 4 critical; nil when unreadable), the only source of the pressure word in
`SystemDetailView`. RAM used is not pressure: compressed and cached pages keep it high on a Mac
under no pressure at all.

Worth understanding: **"Memory Used" includes compressed pages.** On a heavily oversubscribed
Mac (e.g. 43 GB logical on 16 GB physical) freeing a page just lets macOS page an active app
back in, so the gauge stays near max even as Pause genuinely reclaims gigabytes. That is macOS
behaving correctly — and it's exactly why per-app *resident* memory is the honest metric.

---

## Persistence — three small stores

All atomic JSON in `~/Library/Application Support/Pause/` (path kept stable across the rename — see the naming note below).

| File | Module | Purpose |
|---|---|---|
| `paused.json` | `PausedStore.swift` | Frozen apps. A whole-app record has no `ownerPid`. Window records (`ownerPid` set, the process start time in `launchDate`) from builds that froze single windows still decode; they are resumed and dropped at launch. Pid reuse is guarded by launch date / start time. New fields decode with defaults, so older files stay readable. If Pause is killed, frozen apps are still recognised on next launch. |
| `slept.json` | `SleptStore.swift` | Deep-slept apps. **Essential** — a slept app is gone from `runningApplications`, so without this record it would disappear and be unrecoverable. |
| `settings.json` | `AppSettingsStore.swift` | Per-app idle auto-pause (on/off, minutes), keyed by bundle ID. `excludedFromReclaim` is still decoded, only to migrate it into the Never freeze list. |

---

## Views

| File | Role |
|---|---|
| `MenuView.swift` | The panel: ring gauge, system usage graph, and the list in two sections: PAUSED / ASLEEP (whichever apply) and APPS. While the pointer is in the list the displayed order is pinned by bundle ID (new rows appended, cleared when the panel closes), so a row that changes state stays under the pointer; the sections re-sort when it leaves. Tags: PAUSED, ASLEEP (deep-slept, memory line "Quit, relaunches on Wake"). Rows show resident memory only (footprint is in the detail popover). Running rows have a state line under the memory line: "Busy: in use, git fetch" in secondary text with an hourglass, or "Idle 12 min, pauses in 3 min", or a blank line before the first pass. Pause and Deep Sleep follow it through `BusyGate`; when busy, the state line and the button tooltip show the findings and the clicked button turns into an orange Force (`GatedButton`) for 5 s or until the pointer leaves the row (for Deep Sleep this comes before the warning). Orange is used only for Force and warnings. The sparkline sits directly left of the trailing buttons, so all row graphs share one right edge whatever the name or state line. Right edge of every row: details ("Details and auto-pause"), Deep Sleep, main action (Pause, Resume, or a labelled Wake that shows "Waking..." disabled while the relaunch runs); hover highlights the row and hides nothing. Never-freeze apps show a lock icon (not a button, tooltip "On the Never freeze list") instead of Pause and no state line. The frontmost app's Pause is disabled and dimmed (tooltip "In use: switch to another app to pause it") and its context menu has no Pause or Force Pause; Deep Sleep stays. Right-click on an app row: Pause or Resume, Deep Sleep or Wake (through the same gate and warning as the buttons; on a row shown busy the items read "Force Pause" and "Force Deep Sleep" and act at once, the state line being the warning), "Auto-pause..." (opens the detail popover; absent for never-freeze apps) and a "Never freeze" toggle. The timer badge next to the name shows auto-pause is on; never-freeze apps get none. Icon-only buttons carry VoiceOver labels with the app name. Notices: warnings orange with `exclamationmark.triangle`, confirmations green with `checkmark.circle`. The list gets an explicit height computed from the row and section counts, capped at the screen height (a `ScrollView` has no intrinsic size, so without an explicit height the window collapses; computing rather than measuring keeps the size stable across refreshes; state lines add their count times a fixed line height). The footer gear closes the panel (`dismiss`, then closing the key window, since `dismiss` is not reliable for a `MenuBarExtra` window) and opens the Settings window: `openSettings`, then `NSApp.activate` (an `LSUIElement` app is not active, so the window would open behind the frontmost app); Cmd-, while the panel is key. Footer: Free Up Memory (`memorychip`), "Resume All (N)" (`resumeAll`, paused apps only; the count is dropped when it does not fit) and, only while apps are deep-slept, "Wake all (N)" (`wakeAll`, relaunches them). |
| `DetailViews.swift` | `SparklineView` (scaled from 0 to the window's maximum, so noise stays small), `UsageAreaChart` (plotted against total RAM so normal fluctuation looks normal, not like a mountain range), and the per-app detail popover: "1.2 GB in RAM, 1.5 GB footprint", memory history, auto-pause settings (for a never-freeze app "On the Never freeze list" in their place, and no Pause) and Pause/Resume through `GatedButton` (Pause disabled for the frontmost app, as in the row). |
| `SystemDetailView.swift` | Ring gauge (RAM used), "Memory Pressure" with the kernel level (when it cannot be read: "Memory used" with no pressure word), usage history, App/Wired/Compressed/Free/Swap breakdown, top 6 apps by resident memory (slept apps left out). |
| `ReclaimView.swift` | Free Up Memory: a reviewable checklist of what will be paused, with running totals, before anything happens. Never-freeze apps are not offered. Busy apps (checked in one pass on open; the confirm button waits for it) start unticked with the reason as subtitle. Recording and call apps start unticked. The header says how many running apps are not offered because of the Never freeze list; the total reads "Up to X reclaimable"; the confirm button uses the default accent. When "Add the unticked apps to Never freeze" is ticked (off by default), the unticked apps that are not busy are appended to `neverFreeze`. |
| `SettingsView.swift` | The SwiftUI `Settings` scene: a window with the tabs General (start at login; walkthrough; GitHub link), Busy Conditions and Never Freeze. A window rather than popover pages: the regex list and app lists outgrow a popover, which also closes as soon as focus moves. |
| `BusySettingsView.swift` | Settings > Busy Conditions: one checkbox per condition, CPU threshold, and the editable regex list (invalid entries are marked and not saved). |
| `NeverFreezeSettingsView.swift` | Settings > Never Freeze: the list with app name and icon where the app is installed (`urlForApplication(withBundleIdentifier:)`), else the bundle ID; remove buttons, "Add running app..." (listed apps not on the list) and "Restore defaults". |
| `DeepSleepWarningView.swift` | Warning before a Deep Sleep: explains Deep Sleep actually quits the app, reports that app's restore status, offers to enable window restore. Shown every time unless the app's restore status is `.good` and the warning was confirmed once (`PauseFlags.hasSeenDeepSleepWarning`). |
| `PauseApp.swift` | `MenuBarExtra` and `Settings` scenes plus the `NSApplicationDelegate`. Presents the first-run walkthrough in a real `NSWindow` (an `LSUIElement` app isn't activated by default, so it calls `NSApp.activate` explicitly), and resumes every frozen app on quit so nothing is ever stranded. |
| `OnboardingView.swift` | Four-page animated walkthrough: welcome, the two tiers, Free Up Memory (an illustrated checklist with "up to X can be reclaimed"), and where to find the app + start-at-login. Exists because a menu-bar-only app with no Dock icon is easy to lose immediately after installing. |
| `LaunchAtLogin.swift` | `SMAppService.mainApp` wrapper. Registration is idempotent (registering when already enabled throws), and the status is read back afterwards — `register()` can succeed while the item still needs approval, or not take effect when the app runs from a DMG or build folder. |

> **Naming note.** The product is *Auto Pause Mac Apps*; the UI and `CFBundleName` /
> `CFBundleDisplayName` say *Auto Pause*. The bundle stays `Auto Pause Mac Apps.app` (installs,
> login item), and the SwiftPM target and binary are `AutoPauseMacApps`. The Application Support directory deliberately remains `Pause/` — renaming
> it would orphan existing records and strand apps that users currently have frozen.
