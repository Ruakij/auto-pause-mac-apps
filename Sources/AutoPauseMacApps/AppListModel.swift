import AppKit
import Combine
import Foundation

enum AppState: Equatable {
    case running
    case paused    // SIGSTOP'd: alive, frozen, instantly resumable
    case sleeping  // quit with state preserved: 100% of RAM and swap released
}

struct AppEntry: Identifiable, Equatable {
    let id: String            // pid for live apps, bundleID for sleeping ones
    let pid: pid_t?           // nil once sleeping
    let name: String
    let bundleID: String?
    let icon: NSImage?
    let resident: UInt64      // RAM actually held right now
    let footprint: UInt64     // incl. compressed + swapped pages
    let reclaimedBytes: UInt64
    let state: AppState
    let launchDate: Date?
    let history: [UInt64]
    /// Window groups frozen on their own, and the app's window count when a mapping is known.
    var frozenWindows: Int = 0
    var windowCount: Int? = nil
    /// On the Never freeze list: no Pause, no window Pause, no state line.
    var neverFreeze = false

    var canDeepSleep: Bool { state != .sleeping }
}

/// One process of an expanded row. View-only.
struct ProcessStat: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let role: String?
    /// Depth in the app's process tree, the app itself at 0.
    let depth: Int
    let resident: UInt64
    /// Since the previous refresh; nil on the first sample.
    let cpuPercent: Double?
    let stopped: Bool
    var id: pid_t { pid }
}

struct WindowDetail: Identifiable, Equatable {
    let id: Int
    let title: String
    let processes: [ProcessStat]
    let frozen: Bool
    var resident: UInt64 { processes.reduce(0) { $0 + $1.resident } }
    var cpuPercent: Double? {
        let values = processes.compactMap(\.cpuPercent)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

/// Contents of an expanded row: the flat process tree, or windows plus the shared rest.
struct AppDetail: Equatable {
    var processes: [ProcessStat]
    /// Nil for apps without a window mapping.
    var windows: [WindowDetail]?
    var shared: [ProcessStat]
}

struct WindowKey: Hashable {
    let pid: pid_t
    let window: Int
}

/// What an app or window row shows under its memory line while the panel is open.
struct LiveState: Equatable {
    /// Why it counts as busy ("in use", then the findings); empty when idle.
    var busy: [String]
    var idleSince: Date?
    /// When its auto-pause timer fires; nil without auto-pause.
    var pausesAt: Date?

    var busyText: String { "Busy: " + busy.joined(separator: ", ") }

    func text(now: Date = Date()) -> String {
        if !busy.isEmpty { return busyText }
        var text = "Idle"
        if let idleSince { text += " " + Self.minutes(Int(now.timeIntervalSince(idleSince) / 60)) }
        if let pausesAt { text += ", pauses in " + Self.minutes(Int((pausesAt.timeIntervalSince(now) / 60).rounded(.up))) }
        return text
    }

    private static func minutes(_ m: Int) -> String {
        m < 1 ? "<1 min" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }
}

@MainActor
final class AppListModel: ObservableObject {
    @Published var entries: [AppEntry] = []
    @Published var pausedCount: Int = 0
    @Published var totalMemory: UInt64 = UInt64(ProcessInfo.processInfo.physicalMemory)
    @Published var usedMemory: UInt64 = 0
    @Published var systemStats: SystemStats = .current()
    @Published var systemHistory: [UInt64] = []
    /// Transient message shown in the panel, e.g. when an app refuses to sleep.
    @Published var notice: String?
    /// Everything suspended by the last Local Model Mode run, so it can be undone exactly.
    @Published var reclaimSession: [pid_t] = []
    @Published var busySettings = BusySettings.load() {
        didSet { busySettings.save() }
    }
    /// Bundle IDs that are never frozen, by anything; see `freeze(root:bundleID:)`.
    @Published var neverFreeze = NeverFreezeList.load() {
        didSet {
            NeverFreezeList.save(neverFreeze)
            rescheduleAutoPause()
            refresh()
        }
    }
    /// Live state per app and per window group, computed while the panel is open; absent
    /// until a pass could measure it.
    @Published private(set) var appStates: [pid_t: LiveState] = [:]
    @Published private(set) var windowStates: [WindowKey: LiveState] = [:]
    /// App rows expanded into their processes; only these are sampled per process.
    @Published private(set) var expanded: Set<pid_t> = []
    @Published private(set) var details: [pid_t: AppDetail] = [:]
    /// Window groups frozen on their own, over all apps.
    @Published private(set) var frozenWindowCount = 0

    /// Previous CPU sample per process of expanded rows, for the CPU % between refreshes.
    private var cpuSamples: [pid_t: (cpu: UInt64, at: UInt64)] = [:]
    private struct CachedMapping {
        let mapping: WindowMapping?
        let at: Date
        /// Direct children of the app when fetched; a window opening or closing changes them.
        let children: Set<pid_t>
    }
    private var mappings: [pid_t: CachedMapping] = [:]
    private var mappingRequests: [pid_t: Task<WindowMapping?, Never>] = [:]
    private let mappingMaxAge: TimeInterval = 30
    /// AX focus observers for apps with frozen windows or per-window auto-pause.
    private var focusObservers: [pid_t: WindowFocusObserver] = [:]
    /// Focused window of the frontmost app, when it is a mapped app.
    private var focusedWindow: [pid_t: Int] = [:]
    /// Per-window idle clock: when the window last stopped being the focused window of the
    /// frontmost app, or when it was first seen.
    private var windowIdleSince: [WindowKey: Date] = [:]
    private var windowTimers: [WindowKey: Timer] = [:]
    /// When observer creation for the pid last failed; retried after a minute, on app launch or
    /// quit, or when Accessibility trust changes, not on every refresh (each try is AX IPC).
    private var focusObserverFailed: [pid_t: Date] = [:]
    private var wasTrusted = Accessibility.isTrusted
    /// Global mouse-down and key-down monitor, installed while any window is frozen.
    private var eventMonitor: Any?
    /// Exit watchers on the unfrozen renderers of apps with frozen windows, keyed by renderer.
    private var exitWatchers: [pid_t: DispatchSourceProcess] = [:]

    /// Rolling per-app resident samples for the sparklines. ~40 samples at 3s ≈ 2 minutes.
    private var history: [pid_t: [UInt64]] = [:]
    private let historyLimit = 40

    /// Footprint captured at the moment an app was frozen, so we can show what was reclaimed.
    private var footprintAtPause: [pid_t: UInt64] = [:]

    /// Last time each app was frontmost, for idle-based auto-pause.
    private var lastFrontDate: [pid_t: Date] = [:]

    private var timer: Timer?
    /// One-shot auto-pause timer per app, independent of the panel so it fires with it closed.
    private var autoPauseTimers: [pid_t: Timer] = [:]
    private let busy = BusyEvaluator()
    /// A busy app is checked again after this long, without restarting its idle clock.
    private let busyRetryInterval: TimeInterval = 60
    /// An app without a recent CPU sample is sampled and checked again after this long, so
    /// CPU is judged over this window rather than a moment.
    private let cpuSampleRetryInterval: TimeInterval = 30
    /// Shortest CPU interval an auto-pause check judges by. The panel's live pass samples
    /// every 3 s; without this floor an auto-pause check would measure over those 3 s only.
    /// Below `cpuSampleRetryInterval`, so the re-check after a first sample always qualifies.
    private let autoPauseCPUWindow: TimeInterval = 20
    private var livePass: Task<Void, Never>?
    /// Bumped when the panel opens or closes, so a pass of an earlier opening is dropped.
    private var livePassGeneration = 0
    /// Frontmost app as last reported by activation notifications; `isActive` of an app that
    /// just deactivated can still read true.
    private var frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for note in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: note, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.focusObserverFailed = [:]
                    self?.rescheduleAutoPause()
                    self?.refresh()
                }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                             object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.didActivate(pid: app.processIdentifier) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                                             object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.didDeactivate(pid: app.processIdentifier) }
        })
        // One-shot timers do not advance while the Mac sleeps; apps idle overnight are due now.
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rescheduleAutoPause() }
        })
        // Logout and shutdown quit every app, and an app with a frozen window cannot quit.
        observers.append(center.addObserver(forName: NSWorkspace.willPowerOffNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeAllWindows() }
        })
        rescheduleAutoPause()
        refresh()
    }

    /// The activation notification arrives while a frozen app is still stopped, so thawing
    /// here is what lets a Dock click or Cmd-Tab bring it back. Applies to every frozen app,
    /// however it was frozen.
    /// Window groups frozen on their own stay frozen: only the window the user clicks into is
    /// thawed, by the focus observer.
    private func didActivate(pid: pid_t) {
        frontPid = pid
        if focusObservers[pid] != nil {
            // A click into the window that was already focused changes no focus, so read the
            // focused window once activation has settled.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard frontPid == pid else { return }
                noteFocus(pid: pid, title: Accessibility.focusedWindowTitle(pid: pid))
            }
        }
        if ProcessControl.isStopped(pid) || PausedStore.shared.contains(pid: pid) {
            ProcessControl.resumeTree(root: pid, keepStopped: windowRecordPids(pid))
            PausedStore.shared.remove(pid: pid)
            footprintAtPause[pid] = nil
            reclaimSession.removeAll { $0 == pid }
            lastFrontDate[pid] = Date()
            refresh()
        } else {
            lastFrontDate[pid] = Date()
        }
        // Cancels the app timer of the frontmost app; re-arms window timers after a resume.
        scheduleAutoPause(pid)
    }

    /// The idle clock starts when an app leaves the front, not when it came there.
    private func didDeactivate(pid: pid_t) {
        if frontPid == pid { frontPid = nil }
        if let window = focusedWindow.removeValue(forKey: pid) {
            windowIdleSince[WindowKey(pid: pid, window: window)] = Date()
        }
        lastFrontDate[pid] = Date()
        scheduleAutoPause(pid)
    }

    func startRefreshing() {
        timer?.invalidate()
        livePassGeneration += 1
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
        livePassGeneration += 1
        appStates = [:]
        windowStates = [:]
    }

    func runningApp(for entry: AppEntry) -> NSRunningApplication? {
        guard let pid = entry.pid else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    private func listedApps() -> [NSRunningApplication] {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPid
        }
    }

    func refresh() {
        let apps = listedApps()

        PausedStore.shared.pruneStale(currentApps: apps.map { ($0.processIdentifier, $0.launchDate) })
        SleptStore.shared.prune(runningBundleIDs: Set(apps.compactMap(\.bundleIdentifier)))

        let livePids = Set(apps.map(\.processIdentifier))
        history = history.filter { livePids.contains($0.key) }
        footprintAtPause = footprintAtPause.filter { livePids.contains($0.key) }
        expanded = expanded.filter { livePids.contains($0) }
        mappings = mappings.filter { livePids.contains($0.key) }

        var newEntries: [AppEntry] = []

        for app in apps {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }

            let paused = ProcessControl.isStopped(pid) || PausedStore.shared.contains(pid: pid)
            let mem = ProcessControl.treeMemory(root: pid)

            if !paused {
                var samples = history[pid] ?? []
                samples.append(mem.resident)
                if samples.count > historyLimit { samples.removeFirst(samples.count - historyLimit) }
                history[pid] = samples
            }

            // Everything the frozen app has handed back since it was frozen.
            let reclaimed = paused
                ? (footprintAtPause[pid].map { $0 > mem.resident ? $0 - mem.resident : 0 } ?? 0)
                : 0

            newEntries.append(AppEntry(
                id: String(pid),
                pid: pid,
                name: app.localizedName ?? "Unknown",
                bundleID: app.bundleIdentifier,
                icon: app.icon,
                resident: mem.resident,
                footprint: mem.footprint,
                reclaimedBytes: reclaimed,
                state: paused ? .paused : .running,
                launchDate: app.launchDate,
                history: history[pid] ?? [],
                frozenWindows: Set(PausedStore.shared.windowRecords(owner: pid).compactMap(\.windowId)).count,
                windowCount: mappings[pid]?.mapping?.groups.count,
                neverFreeze: isNeverFreeze(app.bundleIdentifier)
            ))
        }

        // Sleeping apps are no longer processes; surface them from the store.
        for rec in SleptStore.shared.records {
            newEntries.append(AppEntry(
                id: rec.bundleID,
                pid: nil,
                name: rec.name,
                bundleID: rec.bundleID,
                icon: rec.icon,
                resident: 0,
                footprint: 0,
                reclaimedBytes: rec.reclaimedBytes,
                state: .sleeping,
                launchDate: nil,
                history: []
            ))
        }

        // Suspended apps pin to the top: they hold 0 resident RAM, so sorting purely by
        // memory buried them under every running app and made them hard to bring back.
        // Running apps below, heaviest first.
        entries = newEntries.sorted { lhs, rhs in
            let lSuspended = lhs.state != .running
            let rSuspended = rhs.state != .running
            if lSuspended != rSuspended { return lSuspended }
            if lSuspended && rSuspended {
                // Sleeping before merely frozen; then by how much each gave back.
                if (lhs.state == .sleeping) != (rhs.state == .sleeping) { return lhs.state == .sleeping }
                return lhs.reclaimedBytes > rhs.reclaimedBytes
            }
            return lhs.resident > rhs.resident
        }
        pausedCount = entries.filter { $0.state != .running }.count
        frozenWindowCount = entries.reduce(0) { $0 + $1.frozenWindows }

        var newDetails: [pid_t: AppDetail] = [:]
        for app in apps where expanded.contains(app.processIdentifier) {
            updateMapping(for: app)
            newDetails[app.processIdentifier] = detail(for: app)
        }
        details = newDetails
        let sampled = Set(newDetails.values.flatMap { $0.processes.map(\.pid) })
        cpuSamples = cpuSamples.filter { sampled.contains($0.key) }
        syncFocusObservers()
        syncEventMonitor()
        syncExitWatchers()
        startLivePass(apps)

        let stats = SystemStats.current()
        systemStats = stats
        usedMemory = stats.usedBytes
        systemHistory.append(stats.usedBytes)
        if systemHistory.count > historyLimit { systemHistory.removeFirst(systemHistory.count - historyLimit) }
    }

    // MARK: - Local Model Mode

    /// Apps that Free Up Memory may offer to pause.
    ///
    /// Never includes this app, the app you're currently using, or anything you've
    /// previously opted out of. Background services are deliberately absent: freezing
    /// daemons broke the machine badly enough to make the feature unusable.
    var reclaimCandidates: [AppEntry] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return entries.filter { entry in
            guard entry.state == .running, !entry.neverFreeze, let pid = entry.pid else { return false }
            guard pid != frontmost else { return false }
            guard !ProcessControl.treeContainsSelf(root: pid) else { return false }
            return !AppSettingsStore.shared.settings(for: entry.bundleID).excludedFromReclaim
        }
        .sorted { $0.resident > $1.resident }
    }

    /// Pause exactly the apps the user ticked — no target-chasing, no extras.
    func reclaim(selected: [AppEntry]) {
        var freed: UInt64 = 0
        var touched: [pid_t] = []
        var skipped: [String] = []

        for entry in selected {
            guard let pid = entry.pid else { continue }
            footprintAtPause[pid] = entry.footprint
            guard freeze(root: pid, bundleID: entry.bundleID) else {
                skipped.append(entry.name)   // refused, e.g. it would have frozen us
                continue
            }
            PausedStore.shared.add(PausedRecord(
                pid: pid, bundleID: entry.bundleID, name: entry.name, launchDate: entry.launchDate))
            cancelWindowTimers(pid)
            freed += entry.resident
            touched.append(pid)
        }

        reclaimSession = touched
        if touched.isEmpty {
            notice = "Nothing was paused."
        } else {
            notice = "Paused \(touched.count) app\(touched.count == 1 ? "" : "s"), freeing about \(MenuView.fmt(freed))."
        }
        if !skipped.isEmpty {
            notice = (notice ?? "") + " Skipped \(skipped.joined(separator: ", "))."
        }
        refresh()
    }

    /// Undo exactly what the last reclaim froze, leaving anything you froze by hand alone.
    func restoreReclaimSession() {
        for pid in reclaimSession {
            ProcessControl.resumeTree(root: pid, keepStopped: windowRecordPids(pid))
            PausedStore.shared.remove(pid: pid)
            footprintAtPause[pid] = nil
            lastFrontDate[pid] = Date()
            scheduleAutoPause(pid)
        }
        notice = "Restored \(reclaimSession.count) app\(reclaimSession.count == 1 ? "" : "s")."
        reclaimSession = []
        refresh()
    }

    /// Remember that an app should never be offered by Free Up Memory again.
    func setExcludedFromReclaim(_ excluded: Bool, for entry: AppEntry) {
        guard let id = entry.bundleID, !id.isEmpty else { return }
        var settings = AppSettingsStore.shared.settings(for: id)
        settings.bundleID = id
        settings.excludedFromReclaim = excluded
        AppSettingsStore.shared.update(settings)
    }

    // MARK: - Auto-pause

    /// Rebuilds every auto-pause timer: on start, launch and termination, and when a setting
    /// changes. Apps without auto-pause, the frontmost one and frozen ones get none.
    func rescheduleAutoPause() {
        let apps = listedApps()
        let livePids = Set(apps.map(\.processIdentifier))
        lastFrontDate = lastFrontDate.filter { livePids.contains($0.key) }
        focusedWindow = focusedWindow.filter { livePids.contains($0.key) }
        windowIdleSince = windowIdleSince.filter { livePids.contains($0.key.pid) }
        for pid in autoPauseTimers.keys where !livePids.contains(pid) { cancelAutoPause(pid) }
        for key in windowTimers.keys where !livePids.contains(key.pid) { windowTimers.removeValue(forKey: key)?.invalidate() }
        for app in apps where app.processIdentifier > 0 {
            scheduleAutoPause(app.processIdentifier, app: app)
        }
        syncFocusObservers()
    }

    private func cancelAutoPause(_ pid: pid_t) {
        autoPauseTimers.removeValue(forKey: pid)?.invalidate()
    }

    /// Arms the timer for `lastFrontDate + minutes`, or for `at` when re-checking a busy app.
    /// Apps with per-window auto-pause get window timers instead.
    private func scheduleAutoPause(_ pid: pid_t, app: NSRunningApplication? = nil, at: Date? = nil) {
        cancelAutoPause(pid)
        guard let app = app ?? NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        if usesWindowAutoPause(app) {
            // A frozen app idles as a whole; its windows are re-armed when it resumes.
            if isFrozenWhole(pid) { cancelWindowTimers(pid) } else { scheduleWindowTimers(pid, app: app) }
            return
        }
        cancelWindowTimers(pid)
        let settings = AppSettingsStore.shared.settings(for: app.bundleIdentifier)
        guard settings.autoPauseEnabled, app.activationPolicy == .regular, pid != frontPid,
              !isNeverFreeze(app.bundleIdentifier), !ProcessControl.isStopped(pid), !PausedStore.shared.contains(pid: pid) else { return }
        if lastFrontDate[pid] == nil { lastFrontDate[pid] = app.launchDate ?? Date() }
        let due = at ?? lastFrontDate[pid]!.addingTimeInterval(TimeInterval(settings.autoPauseMinutes * 60))
        let timer = Timer(fire: max(due, Date()), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.autoPauseFired(pid) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        autoPauseTimers[pid] = timer
    }

    /// Freezes the app unless it is busy or something blocks every automatic pause; then it
    /// is checked again later. The idle clock stays as it is, so the app is frozen on the
    /// first check that finds it idle.
    private func autoPauseFired(_ pid: pid_t) {
        autoPauseTimers[pid] = nil
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular, pid != frontPid, !usesWindowAutoPause(app) else { return }
        let since = lastFrontDate[pid]
        let settings = busySettings
        Task { @MainActor in
            let blockers = await busy.systemBlockers()
            let findings = blockers.isEmpty
                ? await busy.findings(roots: [pid], settings: settings, waitForCPU: false,
                                      minCPUWindow: autoPauseCPUWindow)[0] : []
            // The user may have switched to it, paused it or changed its setting meanwhile.
            guard autoPauseTimers[pid] == nil, lastFrontDate[pid] == since,
                  !app.isTerminated, app.activationPolicy == .regular, pid != frontPid,
                  AppSettingsStore.shared.settings(for: app.bundleIdentifier).autoPauseEnabled,
                  !usesWindowAutoPause(app),
                  !ProcessControl.isStopped(pid), !PausedStore.shared.contains(pid: pid) else { return }
            guard let findings else {
                scheduleAutoPause(pid, app: app, at: Date().addingTimeInterval(cpuSampleRetryInterval))
                return
            }
            if !blockers.isEmpty || !findings.isEmpty {
                scheduleAutoPause(pid, app: app, at: Date().addingTimeInterval(busyRetryInterval))
                return
            }
            let footprint = ProcessControl.treeMemory(root: pid).footprint
            guard freeze(root: pid, bundleID: app.bundleIdentifier) else { return }
            footprintAtPause[pid] = footprint
            PausedStore.shared.add(PausedRecord(
                pid: pid, bundleID: app.bundleIdentifier,
                name: app.localizedName ?? "Unknown", launchDate: app.launchDate))
            cancelWindowTimers(pid)
            refresh()
        }
    }

    // MARK: - Busy checks

    /// What keeps this app busy right now; empty if nothing does.
    func busyFindings(for entry: AppEntry) async -> [BusyFinding] {
        guard let pid = entry.pid else { return [] }
        return await busy.findings(roots: [pid], settings: busySettings)[0] ?? []
    }

    /// What keeps these processes (one window group) busy right now.
    func busyFindings(pids: [pid_t]) async -> [BusyFinding] {
        await busy.findings(pids: pids, settings: busySettings) ?? []
    }

    /// Busy findings for several apps in one pass, keyed by entry id.
    func busyFindings(for entries: [AppEntry]) async -> [String: [BusyFinding]] {
        let live = entries.filter { $0.pid != nil }
        let results = await busy.findings(roots: live.compactMap(\.pid), settings: busySettings)
        return Dictionary(uniqueKeysWithValues: zip(live.map(\.id), results.map { $0 ?? [] }))
    }

    // MARK: - Live state

    /// One busy pass over every listed app and every shown window group, off the main thread,
    /// on each refresh while the panel is open. CPU is measured since the previous pass, so
    /// the first pass after a while yields no state for most rows; the next one, 3 s later,
    /// does. Never-freeze apps, frozen apps and frozen windows get no state.
    private func startLivePass(_ apps: [NSRunningApplication]) {
        guard timer != nil, livePass == nil else { return }
        let roots = apps.filter { !isNeverFreeze($0.bundleIdentifier) && !isFrozenWhole($0.processIdentifier) }
            .map(\.processIdentifier)
        let rootSet = Set(roots)
        var windows: [(key: WindowKey, pids: [pid_t])] = []
        for (pid, detail) in details where rootSet.contains(pid) {
            for w in detail.windows ?? [] where !w.frozen {
                windows.append((WindowKey(pid: pid, window: w.id), w.processes.map(\.pid)))
            }
        }
        let generation = livePassGeneration
        let settings = busySettings
        livePass = Task { @MainActor in
            let results = await busy.findings(roots: roots, groups: windows.map(\.pids), settings: settings,
                                              waitForCPU: false)
            livePass = nil
            guard generation == livePassGeneration else { return }
            var newApps: [pid_t: LiveState] = [:]
            var appIdle: [pid_t: Date] = [:]
            for (pid, found) in zip(roots, results) {
                let inUse = pid == frontPid
                guard found != nil || inUse else { continue }
                let idle = lastFrontDate[pid] ?? NSRunningApplication(processIdentifier: pid)?.launchDate
                appIdle[pid] = idle
                newApps[pid] = LiveState(busy: (inUse ? ["in use"] : []) + (found ?? []).details,
                                         idleSince: idle,
                                         pausesAt: autoPauseTimers[pid].flatMap { $0.isValid ? $0.fireDate : nil })
            }
            let focused = frontPid.flatMap { pid in rootSet.contains(pid) ? focusedWindowId(pid) : nil }
            var newWindows: [WindowKey: LiveState] = [:]
            for (window, found) in zip(windows, results.dropFirst(roots.count)) {
                let key = window.key
                let inUse = key.pid == frontPid && key.window == focused
                guard found != nil || inUse else { continue }
                newWindows[key] = LiveState(
                    busy: (inUse ? ["in use"] : []) + (found ?? []).details,
                    idleSince: windowIdleSince[key] ?? (key.pid == frontPid ? nil : appIdle[key.pid]),
                    pausesAt: windowTimers[key].flatMap { $0.isValid ? $0.fireDate : nil })
            }
            appStates = newApps
            windowStates = newWindows
        }
    }

    /// The focused window of the frontmost app: tracked by the focus observer when there is
    /// one, else read once through Accessibility.
    private func focusedWindowId(_ pid: pid_t) -> Int? {
        if let id = focusedWindow[pid] { return id }
        guard Accessibility.isTrusted, !isFrozenWhole(pid), let groups = mappings[pid]?.mapping?.groups,
              let title = Accessibility.focusedWindowTitle(pid: pid) else { return nil }
        return WindowGroups.match(axTitle: title, in: groups)?.id
    }

    // MARK: - Never freeze

    func isNeverFreeze(_ bundleID: String?) -> Bool {
        bundleID.map(neverFreeze.contains) ?? false
    }

    /// The one place anything is frozen: a manual Pause, auto-pause, Free Up Memory, a refused
    /// Deep Sleep and window groups (`root` is then a window root of the app). Apps on the
    /// Never freeze list are refused here, with no Force. `pauseTree` keeps its own guard
    /// against freezing this process.
    private func freeze(root: pid_t, bundleID: String?) -> Bool {
        guard !isNeverFreeze(bundleID) else { return false }
        return ProcessControl.pauseTree(root: root)
    }

    // MARK: - Actions

    func pause(_ entry: AppEntry) {
        guard let pid = entry.pid else { return }
        footprintAtPause[pid] = entry.footprint
        guard freeze(root: pid, bundleID: entry.bundleID) else { return }
        PausedStore.shared.add(PausedRecord(
            pid: pid, bundleID: entry.bundleID, name: entry.name, launchDate: entry.launchDate))
        cancelWindowTimers(pid)
        refresh()
    }

    func resume(_ entry: AppEntry) {
        if entry.state == .sleeping {
            wake(entry)
            return
        }
        guard let pid = entry.pid else { return }
        ProcessControl.resumeTree(root: pid, keepStopped: windowRecordPids(pid))
        PausedStore.shared.remove(pid: pid)
        footprintAtPause[pid] = nil
        lastFrontDate[pid] = Date()
        scheduleAutoPause(pid)
        refresh()
    }

    func deepSleep(_ entry: AppEntry) {
        guard let app = runningApp(for: entry), let pid = entry.pid else { return }
        let footprint = entry.footprint
        // Its frozen windows could not handle the quit.
        for rec in PausedStore.shared.windowRecords(owner: pid) {
            if rec.isLive { ProcessControl.resumeTree(root: rec.pid) }
            PausedStore.shared.remove(pid: rec.pid)
        }
        Task { @MainActor in
            let result = await DeepSleepController.sleep(app: app, name: entry.name, footprint: footprint)
            switch result {
            case .slept:
                PausedStore.shared.remove(pid: pid)
                footprintAtPause[pid] = nil
            case .refused:
                // Almost always an unsaved-work save sheet. Leave it frozen instead, unless
                // it must never be frozen.
                guard freeze(root: pid, bundleID: entry.bundleID) else {
                    notice = "\(entry.name) has unsaved work, so it was left running instead of quit."
                    break
                }
                notice = "\(entry.name) has unsaved work, so it was left frozen instead of quit."
                footprintAtPause[pid] = footprint
                PausedStore.shared.add(PausedRecord(
                    pid: pid, bundleID: entry.bundleID, name: entry.name, launchDate: entry.launchDate))
                cancelWindowTimers(pid)
            case .failed(let message):
                notice = "\(entry.name): \(message)"
            }
            refresh()
        }
    }

    func wake(_ entry: AppEntry) {
        guard let rec = SleptStore.shared.records.first(where: { $0.bundleID == entry.id }) else { return }
        Task { @MainActor in
            switch await DeepSleepController.wake(rec) {
            case .success:
                notice = nil
            case .failure(let error):
                notice = "Couldn't wake \(rec.name): \(error.localizedDescription). It's still listed — try again."
            }
            refresh()
        }
    }

    func resumeAll() {
        for rec in PausedStore.shared.resumeOrder {
            // A window record's pid may belong to another process by now.
            if rec.ownerPid == nil || rec.isLive { ProcessControl.resumeTree(root: rec.pid) }
            PausedStore.shared.remove(pid: rec.pid)
            if let owner = rec.ownerPid, let window = rec.windowId {
                windowIdleSince[WindowKey(pid: owner, window: window)] = Date()
            }
        }
        for entry in entries where entry.state == .paused {
            if let pid = entry.pid {
                ProcessControl.resumeTree(root: pid)
                lastFrontDate[pid] = Date()
            }
        }
        rescheduleAutoPause()
        let sleeping = SleptStore.shared.records
        Task { @MainActor in
            for rec in sleeping { _ = await DeepSleepController.wake(rec) }
            refresh()
        }
        refresh()
    }

    // MARK: - Process lists

    func toggleExpanded(_ pid: pid_t) {
        if expanded.contains(pid) { expanded.remove(pid) } else { expanded.insert(pid) }
        refresh()
    }

    /// The app's process tree in tree order with memory and CPU, split into windows when the
    /// app has a mapping or frozen window records.
    private func detail(for app: NSRunningApplication) -> AppDetail {
        let pid = app.processIdentifier
        let list = AppProcesses.list(appPid: pid)
        let byParent = Dictionary(grouping: list, by: \.ppid)
        var ordered: [(process: AppProcess, depth: Int)] = []
        func walk(_ p: AppProcess, _ depth: Int) {
            ordered.append((p, depth))
            for child in (byParent[p.pid] ?? []).sorted(by: { $0.pid < $1.pid }) where child.pid != p.pid {
                walk(child, depth + 1)
            }
        }
        if let root = list.first { walk(root, 0) }

        let now = DispatchTime.now().uptimeNanoseconds
        let rows: [ProcessStat] = ordered.map { p, depth in
            var percent: Double?
            if let cpu = ProcessControl.cpuTimeNanos(of: p.pid) {
                if let prev = cpuSamples[p.pid], cpu >= prev.cpu, now > prev.at {
                    percent = Double(cpu - prev.cpu) / Double(now - prev.at) * 100
                }
                cpuSamples[p.pid] = (cpu, now)
            }
            return ProcessStat(pid: p.pid, name: p.name, role: p.role, depth: depth,
                               resident: ProcessControl.memoryInfo(of: p.pid).resident,
                               cpuPercent: percent, stopped: ProcessControl.isStopped(p.pid))
        }

        let mapping = mappings[pid]?.mapping
        let records = PausedStore.shared.windowRecords(owner: pid)
        guard mapping != nil || !records.isEmpty else { return AppDetail(processes: rows, windows: nil, shared: []) }

        var groups: [(id: Int, title: String?, roots: [pid_t])] =
            (mapping?.groups ?? []).map { ($0.id, $0.title, Array($0.anchors.values)) }
        // A frozen window missing from the mapping (fetched before the freeze, or a pid the
        // fetch could not place) is still listed so it can be resumed.
        for (id, recs) in Dictionary(grouping: records, by: { $0.windowId ?? -1 }) where !groups.contains(where: { $0.id == id }) {
            groups.append((id, recs.first?.windowTitle, recs.map(\.pid)))
        }
        let frozenIds = Set(records.compactMap(\.windowId))
        var claimed = Set<pid_t>()
        let windows = groups.sorted { $0.id < $1.id }.map { g -> WindowDetail in
            let pids = Set(g.roots.flatMap { ProcessControl.processTree(root: $0) })
            claimed.formUnion(pids)
            let title = g.title ?? records.first { $0.windowId == g.id }?.windowTitle ?? "Window \(g.id)"
            return WindowDetail(id: g.id, title: title, processes: rows.filter { pids.contains($0.pid) },
                                frozen: frozenIds.contains(g.id))
        }
        return AppDetail(processes: rows, windows: windows, shared: rows.filter { !claimed.contains($0.pid) })
    }

    // MARK: - Window mappings

    /// The app's window mapping, fetched again off the main thread (`code --status` takes
    /// seconds) when older than `maxAge` (30 s by default) or when the app's direct children
    /// changed.
    private func mapping(for app: NSRunningApplication, maxAge: TimeInterval? = nil) async -> WindowMapping? {
        let pid = app.processIdentifier
        let children = Set(ProcessControl.children(of: pid))
        if let cached = mappings[pid], cached.children == children,
           Date().timeIntervalSince(cached.at) < maxAge ?? mappingMaxAge { return cached.mapping }
        if let running = mappingRequests[pid] { return await running.value }
        let request = Task.detached(priority: .utility) { await WindowGroups.mapping(for: app) }
        mappingRequests[pid] = request
        let mapping = await request.value
        mappingRequests[pid] = nil
        mappings[pid] = CachedMapping(mapping: mapping, at: Date(), children: children)
        return mapping
    }

    /// Starts a background fetch if the cached mapping is stale, then rearms the app's window
    /// timers and refreshes. Not for a frozen app: `--status` would wait for it until timeout.
    private func updateMapping(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard mappingRequests[pid] == nil, !isFrozenWhole(pid) else { return }
        if let cached = mappings[pid], Date().timeIntervalSince(cached.at) < mappingMaxAge,
           cached.children == Set(ProcessControl.children(of: pid)) { return }
        Task { @MainActor in
            _ = await mapping(for: app)
            if usesWindowAutoPause(app) { scheduleWindowTimers(pid, app: app) }
            refresh()
        }
    }

    // MARK: - Window freeze

    private func isFrozenWhole(_ pid: pid_t) -> Bool {
        ProcessControl.isStopped(pid) || PausedStore.shared.contains(pid: pid)
    }

    private func windowRecordPids(_ owner: pid_t) -> [pid_t] {
        PausedStore.shared.windowRecords(owner: owner).map(\.pid)
    }

    private func isWindowFrozen(_ key: WindowKey) -> Bool {
        PausedStore.shared.windowRecords(owner: key.pid).contains { $0.windowId == key.window }
    }

    /// The AX title of the group's window when exactly one window carries the mapping's title.
    private func exactAXTitle(of group: WindowGroup, pid: pid_t) -> String? {
        guard let title = group.title else { return nil }
        let wanted = WindowGroups.normalizedSegments(title)
        let hits = Accessibility.windowTitles(pid: pid).filter { WindowGroups.normalizedSegments($0) == wanted }
        return hits.count == 1 ? hits[0] : nil
    }

    /// The window's group and its current AX title, read before a freeze: a frozen renderer
    /// cannot retitle its window, so this is the title a later focus or click reports. A
    /// mapping title that matches no window is stale (the active editor changed), so the
    /// mapping is fetched again first.
    private func windowToFreeze(app: NSRunningApplication, id: Int) async -> (group: WindowGroup, mapping: WindowMapping, title: String?)? {
        let pid = app.processIdentifier
        guard var mapping = await mapping(for: app),
              var group = mapping.groups.first(where: { $0.id == id }) else { return nil }
        var title = exactAXTitle(of: group, pid: pid)
        if title == nil, let fresh = await self.mapping(for: app, maxAge: 2),
           let freshGroup = fresh.groups.first(where: { $0.id == id }) {
            mapping = fresh
            group = freshGroup
            title = exactAXTitle(of: group, pid: pid)
        }
        return (group, mapping, title)
    }

    func pauseWindow(_ entry: AppEntry, window: Int) async {
        guard let app = runningApp(for: entry),
              let target = await windowToFreeze(app: app, id: window),
              !isWindowFrozen(WindowKey(pid: app.processIdentifier, window: window)) else { return }
        freezeWindow(app: app, group: target.group, mapping: target.mapping, title: target.title)
    }

    /// Freezes each root of the group with its tree. Shared processes and the app itself are
    /// never roots; `pauseTree` keeps its own guard against freezing this process. A frozen app
    /// is left alone: its windows resume with it.
    private func freezeWindow(app: NSRunningApplication, group: WindowGroup, mapping: WindowMapping, title: String?) {
        let appPid = app.processIdentifier
        guard !isFrozenWhole(appPid) else { return }
        let shared = Set(mapping.shared).union([appPid])
        let children = Set(ProcessControl.children(of: appPid))
        for role in ["renderer", "extension host", "file watcher"] {
            guard let root = group.anchors[role], !shared.contains(root), children.contains(root),
                  let start = ProcessControl.startTime(of: root),
                  freeze(root: root, bundleID: app.bundleIdentifier) else { continue }
            PausedStore.shared.add(PausedRecord(
                pid: root, bundleID: app.bundleIdentifier, name: app.localizedName ?? "Unknown",
                launchDate: start, ownerPid: appPid, windowId: group.id, windowTitle: title ?? group.title))
        }
        windowTimers.removeValue(forKey: WindowKey(pid: appPid, window: group.id))?.invalidate()
        refresh()
    }

    func resumeWindow(_ entry: AppEntry, window: Int) {
        guard let pid = entry.pid else { return }
        resumeWindow(WindowKey(pid: pid, window: window))
    }

    private func resumeWindow(_ key: WindowKey) {
        for rec in PausedStore.shared.windowRecords(owner: key.pid) where rec.windowId == key.window {
            if rec.isLive { ProcessControl.resumeTree(root: rec.pid) }
            PausedStore.shared.remove(pid: rec.pid)
        }
        windowIdleSince[key] = Date()
        scheduleWindowTimer(key)
        refresh()
    }

    private func resumeWindows(of pid: pid_t) {
        for id in Set(PausedStore.shared.windowRecords(owner: pid).compactMap(\.windowId)) {
            resumeWindow(WindowKey(pid: pid, window: id))
        }
    }

    private func resumeAllWindows() {
        for owner in Set(PausedStore.shared.records.compactMap(\.ownerPid)) { resumeWindows(of: owner) }
    }

    // MARK: - Quit with frozen windows

    /// An app quitting with a frozen window hangs: it waits for that renderer's unload reply.
    /// There is no notification for another app starting to quit, but its other renderers exit
    /// at once, so the exit of any unfrozen renderer thaws the app's frozen windows. A window
    /// closed normally does the same, which costs one re-idle.
    private func syncExitWatchers() {
        var wanted: [pid_t: pid_t] = [:]
        for owner in Set(PausedStore.shared.records.compactMap(\.ownerPid)) {
            let frozen = Set(windowRecordPids(owner))
            for p in AppProcesses.list(appPid: owner)
            where p.ppid == owner && p.role == "renderer" && !frozen.contains(p.pid) {
                wanted[p.pid] = owner
            }
        }
        for (pid, source) in exitWatchers where wanted[pid] == nil {
            source.cancel()
            exitWatchers[pid] = nil
        }
        for (pid, owner) in wanted where exitWatchers[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.exitWatchers.removeValue(forKey: pid)?.cancel()
                    self.resumeWindows(of: owner)
                }
            }
            source.resume()
            exitWatchers[pid] = source
        }
    }

    /// Mouse-down: a click into a window that was frozen while focused moves no focus, so the
    /// clicked window is found by hit test. Key-down: Cmd-Q of a single-window app, where no
    /// other renderer exits to report the quit.
    private func syncEventMonitor() {
        let wanted = frozenWindowCount > 0 && Accessibility.isTrusted
        if wanted, eventMonitor == nil {
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.globalEvent(event) }
            }
        } else if !wanted, let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func globalEvent(_ event: NSEvent) {
        guard let pid = frontPid, !windowRecordPids(pid).isEmpty, !isFrozenWhole(pid) else { return }
        if event.type == .keyDown {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "q" { resumeWindows(of: pid) }
            return
        }
        // AX uses top-left screen coordinates, AppKit bottom-left of the primary screen.
        let location = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        if let title = Accessibility.windowTitle(at: CGPoint(x: location.x, y: height - location.y), pid: pid) {
            noteFocus(pid: pid, title: title)
        }
    }

    // MARK: - Window focus

    /// Observes window focus of apps with frozen windows (to thaw the one clicked into) and of
    /// apps with per-window auto-pause (for their idle clocks). Needs Accessibility. Never for
    /// a stopped app: AX calls to it block until they time out.
    private func syncFocusObservers() {
        let trusted = Accessibility.isTrusted
        if trusted != wasTrusted { focusObserverFailed = [:] }
        wasTrusted = trusted
        var wanted = Set(PausedStore.shared.records.compactMap(\.ownerPid))
        for app in listedApps() where usesWindowAutoPause(app) { wanted.insert(app.processIdentifier) }
        wanted = wanted.filter { !ProcessControl.isStopped($0) }
        for pid in focusObservers.keys where !wanted.contains(pid) { focusObservers[pid] = nil }
        focusObserverFailed = focusObserverFailed.filter { wanted.contains($0.key) && Date().timeIntervalSince($0.value) < 60 }
        guard trusted else { return }
        for pid in wanted where focusObservers[pid] == nil && focusObserverFailed[pid] == nil {
            focusObservers[pid] = WindowFocusObserver(pid: pid) { [weak self] title in
                self?.noteFocus(pid: pid, title: title)
            }
            if focusObservers[pid] == nil {
                focusObserverFailed[pid] = Date()
            } else if frontPid == pid {
                noteFocus(pid: pid, title: Accessibility.focusedWindowTitle(pid: pid))
            }
        }
    }

    /// Focus moved to the window titled `title`: it stops idling, the window it left starts,
    /// and a frozen window is thawed.
    private func noteFocus(pid: pid_t, title: String?) {
        if frontPid == pid {
            let groups = mappings[pid]?.mapping?.groups ?? []
            let id = title.flatMap { WindowGroups.match(axTitle: $0, in: groups)?.id }
            if let old = focusedWindow[pid], old != id {
                let key = WindowKey(pid: pid, window: old)
                windowIdleSince[key] = Date()
                focusedWindow[pid] = id
                scheduleWindowTimer(key)
            }
            focusedWindow[pid] = id
            if let id { windowTimers.removeValue(forKey: WindowKey(pid: pid, window: id))?.invalidate() }
            // A new window, or titles changed since the mapping was fetched.
            if id == nil, title != nil, let app = NSRunningApplication(processIdentifier: pid) { updateMapping(for: app) }
        }
        let records = PausedStore.shared.windowRecords(owner: pid)
        guard let title, !records.isEmpty else { return }
        // A new window opens with focus; its renderer needs an exit watcher.
        syncExitWatchers()
        let frozen = Dictionary(grouping: records.filter { $0.windowId != nil }, by: { $0.windowId! }).map { id, recs in
            WindowGroup(id: id, title: recs.first?.windowTitle, anchors: [:], pids: Set(recs.map(\.pid)))
        }
        if let group = WindowGroups.match(axTitle: title, in: frozen) {
            resumeWindow(WindowKey(pid: pid, window: group.id))
            return
        }
        // A record without the exact AX title (made from a mapping title): place the window
        // through the mapping and compare ids, fetching it again only for a title the cached
        // one does not place, since clicks land here too.
        if let known = mappings[pid]?.mapping.flatMap({ WindowGroups.match(axTitle: title, in: $0.groups) }) {
            let key = WindowKey(pid: pid, window: known.id)
            if isWindowFrozen(key) { resumeWindow(key) }
            return
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        Task { @MainActor in
            guard let mapping = await mapping(for: app, maxAge: 5),
                  let group = WindowGroups.match(axTitle: title, in: mapping.groups) else { return }
            let key = WindowKey(pid: pid, window: group.id)
            if isWindowFrozen(key) { resumeWindow(key) }
        }
    }

    // MARK: - Per-window auto-pause

    /// A mapped app with auto-pause on idles and freezes per window and is never auto-frozen
    /// whole. Without Accessibility the focused window is unknown, so it falls back to the
    /// whole app.
    private func usesWindowAutoPause(_ app: NSRunningApplication) -> Bool {
        AppSettingsStore.shared.settings(for: app.bundleIdentifier).autoPauseEnabled
            && !isNeverFreeze(app.bundleIdentifier)
            && WindowGroups.isSupported(app) && Accessibility.isTrusted
    }

    private func cancelWindowTimers(_ pid: pid_t) {
        for key in windowTimers.keys where key.pid == pid { windowTimers.removeValue(forKey: key)?.invalidate() }
    }

    /// Arms a timer per window of the cached mapping; without one, fetches it first.
    private func scheduleWindowTimers(_ pid: pid_t, app: NSRunningApplication) {
        guard let mapping = mappings[pid]?.mapping else {
            cancelWindowTimers(pid)
            updateMapping(for: app)
            return
        }
        let ids = Set(mapping.groups.map(\.id))
        for key in windowTimers.keys where key.pid == pid && !ids.contains(key.window) {
            windowTimers.removeValue(forKey: key)?.invalidate()
        }
        windowIdleSince = windowIdleSince.filter { $0.key.pid != pid || ids.contains($0.key.window) }
        for id in ids { scheduleWindowTimer(WindowKey(pid: pid, window: id), app: app) }
    }

    /// Arms the window's timer for `windowIdleSince + minutes`, or for `at` on a re-check.
    /// Frozen windows, windows of a frozen app and the focused window of the frontmost app get
    /// none.
    private func scheduleWindowTimer(_ key: WindowKey, app: NSRunningApplication? = nil, at: Date? = nil) {
        windowTimers.removeValue(forKey: key)?.invalidate()
        guard let app = app ?? NSRunningApplication(processIdentifier: key.pid), !app.isTerminated,
              usesWindowAutoPause(app), !isWindowFrozen(key), !isFrozenWhole(key.pid),
              !(frontPid == key.pid && focusedWindow[key.pid] == key.window) else { return }
        let since = windowIdleSince[key] ?? Date()
        windowIdleSince[key] = since
        let minutes = AppSettingsStore.shared.settings(for: app.bundleIdentifier).autoPauseMinutes
        let due = at ?? since.addingTimeInterval(TimeInterval(minutes * 60))
        let timer = Timer(fire: max(due, Date()), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.windowAutoPauseFired(key) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        windowTimers[key] = timer
    }

    /// Freezes the window group unless it is the focused window of the frontmost app, is busy,
    /// or a system blocker holds; then it is checked again later, as for whole apps.
    private func windowAutoPauseFired(_ key: WindowKey) {
        windowTimers[key] = nil
        guard let app = NSRunningApplication(processIdentifier: key.pid), !app.isTerminated,
              usesWindowAutoPause(app), !isFrozenWhole(key.pid) else { return }
        let since = windowIdleSince[key]
        let settings = busySettings
        Task { @MainActor in
            // Closed windows simply drop out.
            guard let target = await windowToFreeze(app: app, id: key.window) else { return }
            if frontPid == key.pid {
                // A focused window that cannot be identified counts as this one.
                let front = Accessibility.focusedWindowTitle(pid: key.pid)
                    .flatMap { WindowGroups.match(axTitle: $0, in: target.mapping.groups) }
                if front == nil || front?.id == key.window {
                    scheduleWindowTimer(key, app: app, at: Date().addingTimeInterval(busyRetryInterval))
                    return
                }
            }
            let blockers = await busy.systemBlockers()
            let findings = blockers.isEmpty
                ? await busy.findings(pids: Array(target.group.pids), settings: settings, waitForCPU: false,
                                      minCPUWindow: autoPauseCPUWindow) : []
            // Focus may have moved, or the window or app frozen, resumed or rescheduled meanwhile.
            guard windowTimers[key] == nil, windowIdleSince[key] == since, !app.isTerminated,
                  usesWindowAutoPause(app), !isWindowFrozen(key), !isFrozenWhole(key.pid),
                  !(frontPid == key.pid && focusedWindow[key.pid] == key.window) else { return }
            guard let findings else {
                scheduleWindowTimer(key, app: app, at: Date().addingTimeInterval(cpuSampleRetryInterval))
                return
            }
            if !blockers.isEmpty || !findings.isEmpty {
                scheduleWindowTimer(key, app: app, at: Date().addingTimeInterval(busyRetryInterval))
                return
            }
            freezeWindow(app: app, group: target.group, mapping: target.mapping, title: target.title)
        }
    }
}
