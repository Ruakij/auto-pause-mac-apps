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
    /// On the Never freeze list: no Pause, no state line.
    var neverFreeze = false
    /// Processes in the app's tree, the app included.
    var processCount = 1
    /// Subtrees of the app frozen on their own (subprocess records).
    var pausedProcesses = 0

    var canDeepSleep: Bool { state != .sleeping }
    /// Frozen whole or with some processes frozen: Resume All and the menu-bar icon count it.
    var hasPaused: Bool { state == .paused || pausedProcesses > 0 }
}

/// One process of an expanded row.
struct ProcessStat: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let role: String?
    /// Depth in the app's process tree, the app itself at 0.
    let depth: Int
    let resident: UInt64
    let footprint: UInt64
    /// This process and its descendants.
    let subtreeResident: UInt64
    let subtreeFootprint: UInt64
    /// This process and its descendants, for the CPU sum of a collapsed node.
    let subtree: [pid_t]
    let stopped: Bool
    /// Frozen on its own: a subprocess record holds it.
    let frozen: Bool
    /// May be paused on its own: not the app process, and no process of its subtree is a
    /// Chromium shared role, of another user or another listed app.
    let freezable: Bool
    /// Footprint at freeze minus subtree resident now, for frozen nodes.
    let reclaimed: UInt64
    var descendants: Int { subtree.count - 1 }
    var id: pid_t { pid }
}

/// Contents of an expanded row: the app's whole process tree in tree order, app first, the
/// children of every node by subtree resident, heaviest first.
struct AppDetail: Equatable {
    var processes: [ProcessStat]

    /// The rows shown: everything below a collapsed node is hidden. The app (depth 0) is
    /// always open.
    func visible(expanded: Set<pid_t>) -> [ProcessStat] {
        var rows: [ProcessStat] = []
        var hiddenBelow: Int?
        for p in processes {
            if let depth = hiddenBelow {
                if p.depth > depth { continue }
                hiddenBelow = nil
            }
            rows.append(p)
            if p.depth > 0, p.descendants > 0, !expanded.contains(p.pid) { hiddenBelow = p.depth }
        }
        return rows
    }
}

/// What an app row shows under its memory line while the panel is open.
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

/// A message shown above the app list until dismissed or replaced.
struct Notice: Equatable {
    let text: String
    /// Something did not happen as asked; otherwise a confirmation.
    var isWarning = false
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
    @Published var notice: Notice?
    /// Bundle IDs of deep-slept apps whose relaunch is running.
    @Published private(set) var waking: Set<String> = []
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
    /// Live state per app, computed while the panel is open; absent until a pass could
    /// measure it.
    @Published private(set) var appStates: [pid_t: LiveState] = [:]
    /// CPU percent per app tree (100 = one core) from the live pass, the sum the CPU busy
    /// condition judges; absent for frozen apps and until a pass could measure the app.
    @Published private(set) var cpu: [pid_t: Double] = [:]
    /// Rolling per-app CPU figures, one per completed live pass, for the CPU graphs.
    @Published private(set) var cpuHistory: [pid_t: [Double]] = [:]
    /// CPU percent per process of the last live pass; `cpu` is its sum per tree.
    private(set) var processCPU: [pid_t: Double] = [:]

    /// The CPU busy threshold, which the CPU graphs mark; nil while that condition is off.
    var cpuThreshold: Double? {
        busySettings.enabled.contains(.cpu) ? busySettings.cpuThresholdPercent : nil
    }

    /// Rolling per-app resident samples for the sparklines. ~40 samples at 3s ≈ 2 minutes.
    private var history: [pid_t: [UInt64]] = [:]
    private let historyLimit = 40

    /// Footprint captured at the moment an app or subtree was frozen, so we can show what was
    /// reclaimed.
    private var footprintAtPause: [pid_t: UInt64] = [:]

    /// App rows expanded into their process tree; only these are read per process.
    @Published private(set) var expanded: Set<pid_t> = []
    /// Processes whose children are shown; every node below the app starts collapsed.
    @Published private(set) var expandedProcesses: Set<pid_t> = []
    @Published private(set) var details: [pid_t: AppDetail] = [:]
    private struct ProcessLabel {
        let start: Date?
        let name: String
        let role: String?
        let freezable: Bool
    }
    /// Per pid and start time, so the command line is read once per process.
    private var processLabels: [pid_t: ProcessLabel] = [:]
    /// Exit watchers on the unfrozen direct children of apps with frozen subprocesses.
    private var exitWatchers: [pid_t: DispatchSourceProcess] = [:]

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
    /// just deactivated can still read true. Published because rows disable Pause for it.
    @Published private(set) var frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    private var observers: [NSObjectProtocol] = []
    /// Global mouse-down monitor that thaws a paused app whose Dock tile is clicked; installed
    /// only while an app is paused and Accessibility is granted.
    private var dockClickMonitor: Any?

    init() {
        let migrated = AppSettingsStore.shared.takeExcludedFromReclaim().filter { !neverFreeze.contains($0) }
        if !migrated.isEmpty {
            // didSet does not run inside init.
            neverFreeze += migrated
            NeverFreezeList.save(neverFreeze)
        }
        let center = NSWorkspace.shared.notificationCenter
        for note in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: note, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
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
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Accessibility.trustChangedNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.syncDockClickMonitor() }
            }
        })
        resumeForeignRecords()
        rescheduleAutoPause()
        refresh()
    }

    /// Records with an owner and a kind this build does not know: window records (no `kind`)
    /// of builds that froze single windows, or a kind of a newer build. Nothing here would ever
    /// wake them, so they are resumed and dropped before the first refresh.
    private func resumeForeignRecords() {
        for rec in PausedStore.shared.records where rec.isForeign {
            guard let owner = rec.ownerPid else { continue }
            // A process of an app frozen whole resumes with the app; the pid may belong to
            // another process by now.
            let ownerFrozen = PausedStore.shared.contains(pid: owner) && ProcessControl.isStopped(owner)
            if !ownerFrozen, rec.isLive { ProcessControl.resumeTree(root: rec.pid) }
            PausedStore.shared.remove(pid: rec.pid)
        }
    }

    /// The notification arrives while a frozen app is still stopped only when the system makes
    /// it frontmost by itself (LaunchServices: `open -a`, Spotlight, Finder). A Dock click or
    /// Cmd-Tab asks the app to activate itself, which a stopped app never does; the Dock click
    /// is covered by `dockClickMonitor`. Applies to every frozen app, however it was frozen.
    private func didActivate(pid: pid_t) {
        frontPid = pid
        if isFrozen(pid) {
            thaw(pid: pid)
        } else {
            lastFrontDate[pid] = Date()
            // Cancels the timer of the frontmost app.
            scheduleAutoPause(pid)
        }
    }

    /// Frozen whole, or with subprocesses frozen on their own.
    private func isFrozen(_ pid: pid_t) -> Bool {
        isFrozenWhole(pid) || !PausedStore.shared.subprocessRecords(owner: pid).isEmpty
    }

    private func isFrozenWhole(_ pid: pid_t) -> Bool {
        ProcessControl.isStopped(pid) || PausedStore.shared.contains(pid: pid)
    }

    private func dropRecord(_ pid: pid_t) {
        PausedStore.shared.remove(pid: pid)
        footprintAtPause[pid] = nil
    }

    /// The one place a single frozen app is resumed: activation, a Dock click and Resume. Its
    /// frozen subprocesses resume first, then the app if it is frozen whole. It leaves the Free
    /// Up Memory run too, so Restore does not count it.
    private func thaw(pid: pid_t) {
        resumeSubprocesses(of: pid)
        // Only an app frozen whole gets its whole tree resumed: a stopped job in a terminal
        // app's tree is the user's, not ours.
        if isFrozenWhole(pid) { ProcessControl.resumeTree(root: pid) }
        PausedStore.shared.remove(pid: pid)
        footprintAtPause[pid] = nil
        reclaimSession.removeAll { $0 == pid }
        lastFrontDate[pid] = Date()
        // Cancels the timer when `pid` is frontmost, restarts the idle clock otherwise.
        scheduleAutoPause(pid)
        refresh()
    }

    /// Installs the Dock click monitor while an app is paused and Accessibility is granted,
    /// removes it otherwise, so no global monitor runs without need.
    private func syncDockClickMonitor() {
        let wanted = entries.contains { $0.state == .paused } && Accessibility.isTrusted
        if wanted, dockClickMonitor == nil {
            dockClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.dockClicked() }
            }
        } else if !wanted, let monitor = dockClickMonitor {
            NSEvent.removeMonitor(monitor)
            dockClickMonitor = nil
        }
    }

    /// Thaws on mouse-down, before the Dock sends its activation request on mouse-up, so the
    /// running app answers that request and comes forward.
    private func dockClicked() {
        guard let path = Accessibility.dockApplicationURL(at: Accessibility.pointerLocation)?.resolvingSymlinksInPath().path,
              let app = listedApps().first(where: { $0.bundleURL?.resolvingSymlinksInPath().path == path }),
              isFrozen(app.processIdentifier) else { return }
        thaw(pid: app.processIdentifier)
    }

    /// The idle clock starts when an app leaves the front, not when it came there.
    private func didDeactivate(pid: pid_t) {
        if frontPid == pid { frontPid = nil }
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
        cpu = [:]
        processCPU = [:]
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
        cpuHistory = cpuHistory.filter { livePids.contains($0.key) }
        let recordPids = Set(PausedStore.shared.records.map(\.pid))
        footprintAtPause = footprintAtPause.filter { livePids.contains($0.key) || recordPids.contains($0.key) }
        expanded = expanded.filter { livePids.contains($0) }
        expandedProcesses = expandedProcesses.filter(ProcessControl.isAlive)
        var newDetails: [pid_t: AppDetail] = [:]
        for pid in expanded { newDetails[pid] = detail(for: pid, apps: livePids) }
        details = newDetails
        let shownPids = Set(newDetails.values.flatMap { $0.processes.map(\.pid) })
        processLabels = processLabels.filter { shownPids.contains($0.key) }

        var newEntries: [AppEntry] = []

        for app in apps {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }

            let paused = isFrozenWhole(pid)
            let tree = ProcessControl.processTree(root: pid)
            let mem = ProcessControl.treeMemory(pids: tree)

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
                neverFreeze: isNeverFreeze(app.bundleIdentifier),
                processCount: tree.count,
                pausedProcesses: PausedStore.shared.subprocessRecords(owner: pid).count
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
        pausedCount = entries.filter { $0.state != .running || $0.hasPaused }.count
        syncDockClickMonitor()
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
    /// Never includes this app, the app you're currently using, or anything on the Never
    /// freeze list. Background services are deliberately absent: freezing
    /// daemons broke the machine badly enough to make the feature unusable.
    var reclaimCandidates: [AppEntry] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return entries.filter { entry in
            guard entry.state == .running, !entry.neverFreeze, let pid = entry.pid else { return false }
            guard pid != frontmost else { return false }
            return !ProcessControl.treeContainsSelf(root: pid)
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
            guard freeze(root: pid, app: pid, bundleID: entry.bundleID) else {
                skipped.append(entry.name)   // refused, e.g. it would have frozen us
                continue
            }
            PausedStore.shared.add(PausedRecord(
                pid: pid, bundleID: entry.bundleID, name: entry.name, launchDate: entry.launchDate))
            freed += entry.resident
            touched.append(pid)
        }

        reclaimSession = touched
        var text = touched.isEmpty
            ? "Nothing was paused."
            : "Paused \(touched.count) app\(touched.count == 1 ? "" : "s"), up to \(MenuView.fmt(freed)) reclaimable."
        if !skipped.isEmpty { text += " Skipped \(skipped.joined(separator: ", "))." }
        notice = Notice(text: text, isWarning: touched.isEmpty || !skipped.isEmpty)
        refresh()
    }

    /// Undo exactly what the last reclaim froze, leaving anything you froze by hand alone.
    func restoreReclaimSession() {
        for pid in reclaimSession {
            resumeSubprocesses(of: pid)
            ProcessControl.resumeTree(root: pid)
            PausedStore.shared.remove(pid: pid)
            footprintAtPause[pid] = nil
            lastFrontDate[pid] = Date()
            scheduleAutoPause(pid)
        }
        notice = Notice(text: "Restored \(reclaimSession.count) app\(reclaimSession.count == 1 ? "" : "s").")
        reclaimSession = []
        refresh()
    }

    // MARK: - Auto-pause

    /// Rebuilds every auto-pause timer: on start, launch and termination, and when a setting
    /// changes. Never-freeze apps, apps without auto-pause, the frontmost one and frozen ones
    /// get none.
    func rescheduleAutoPause() {
        let apps = listedApps()
        let livePids = Set(apps.map(\.processIdentifier))
        lastFrontDate = lastFrontDate.filter { livePids.contains($0.key) }
        for pid in autoPauseTimers.keys where !livePids.contains(pid) { cancelAutoPause(pid) }
        for app in apps where app.processIdentifier > 0 {
            scheduleAutoPause(app.processIdentifier, app: app)
        }
    }

    private func cancelAutoPause(_ pid: pid_t) {
        autoPauseTimers.removeValue(forKey: pid)?.invalidate()
    }

    /// Arms the timer for `lastFrontDate + minutes`, or for `at` when re-checking a busy app.
    private func scheduleAutoPause(_ pid: pid_t, app: NSRunningApplication? = nil, at: Date? = nil) {
        cancelAutoPause(pid)
        guard let app = app ?? NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              !isNeverFreeze(app.bundleIdentifier) else { return }
        let settings = AppSettingsStore.shared.settings(for: app.bundleIdentifier)
        guard settings.autoPauseEnabled, app.activationPolicy == .regular, pid != frontPid,
              !ProcessControl.isStopped(pid), !PausedStore.shared.contains(pid: pid) else { return }
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
              app.activationPolicy == .regular, pid != frontPid else { return }
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
            guard freeze(root: pid, app: pid, bundleID: app.bundleIdentifier) else { return }
            footprintAtPause[pid] = footprint
            PausedStore.shared.add(PausedRecord(
                pid: pid, bundleID: app.bundleIdentifier,
                name: app.localizedName ?? "Unknown", launchDate: app.launchDate))
            refresh()
        }
    }

    // MARK: - Busy checks

    /// What keeps this app busy right now; empty if nothing does.
    func busyFindings(for entry: AppEntry) async -> [BusyFinding] {
        guard let pid = entry.pid else { return [] }
        return await busy.findings(roots: [pid], settings: busySettings)[0] ?? []
    }

    /// Busy findings for several apps in one pass, keyed by entry id.
    func busyFindings(for entries: [AppEntry]) async -> [String: [BusyFinding]] {
        let live = entries.filter { $0.pid != nil }
        let results = await busy.findings(roots: live.compactMap(\.pid), settings: busySettings)
        return Dictionary(uniqueKeysWithValues: zip(live.map(\.id), results.map { $0 ?? [] }))
    }

    // MARK: - Live state

    /// One busy pass over every listed app, off the main thread, on each refresh while the
    /// panel is open. CPU is measured since the previous pass, so the first pass after a while
    /// yields no state for most rows; the next one, 3 s later, does. CPU is measured for every
    /// running app, also with the CPU condition off; never-freeze apps get a CPU figure but no
    /// state. Frozen apps are not measured.
    private func startLivePass(_ apps: [NSRunningApplication]) {
        guard timer != nil, livePass == nil else { return }
        let running = apps.filter { !ProcessControl.isStopped($0.processIdentifier) && !PausedStore.shared.contains(pid: $0.processIdentifier) }
        let roots = running.map(\.processIdentifier)
        let neverFrozen = Set(running.filter { isNeverFreeze($0.bundleIdentifier) }.map(\.processIdentifier))
        let generation = livePassGeneration
        let settings = busySettings
        livePass = Task { @MainActor in
            let pass = await busy.pass(roots: roots, settings: settings, waitForCPU: false, alwaysMeasureCPU: true)
            livePass = nil
            guard generation == livePassGeneration else { return }
            var newCPU: [pid_t: Double] = [:]
            var newHistory = cpuHistory
            for (i, pid) in roots.enumerated() {
                guard let percent = pass.cpuPercent(tree: i) else { continue }
                newCPU[pid] = percent
                newHistory[pid, default: []].append(percent)
                if newHistory[pid]!.count > historyLimit { newHistory[pid]!.removeFirst(newHistory[pid]!.count - historyLimit) }
            }
            processCPU = pass.cpu
            cpu = newCPU
            cpuHistory = newHistory
            var newApps: [pid_t: LiveState] = [:]
            for (pid, found) in zip(roots, pass.findings) where !neverFrozen.contains(pid) {
                let inUse = pid == frontPid
                guard found != nil || inUse else { continue }
                newApps[pid] = LiveState(busy: (inUse ? ["in use"] : []) + (found ?? []).details,
                                         idleSince: lastFrontDate[pid] ?? NSRunningApplication(processIdentifier: pid)?.launchDate,
                                         pausesAt: autoPauseTimers[pid].flatMap { $0.isValid ? $0.fireDate : nil })
            }
            appStates = newApps
        }
    }

    // MARK: - Never freeze

    func isNeverFreeze(_ bundleID: String?) -> Bool {
        bundleID.map(neverFreeze.contains) ?? false
    }

    func isFrontmost(_ pid: pid_t?) -> Bool {
        pid != nil && pid == frontPid
    }

    /// The one place anything is frozen: a manual Pause, a process paused on its own,
    /// auto-pause and Free Up Memory. `root` is the app pid or a process of its tree, `app`
    /// the app it belongs to. Apps on the Never freeze list and the frontmost app are refused
    /// here, checked against the app, with no Force: activating a frozen app is what thaws it,
    /// and the frontmost app gets no activation when clicked, so it would stay frozen. A tree
    /// holding another listed app (a dev build started from a terminal) is refused too: that
    /// app may be frontmost or on the list itself. A subprocess must still be in the app's
    /// tree, and no process below it may be a Chromium shared role (which would stall every
    /// window) or belong to another user. `pauseTree` keeps its own guard against freezing
    /// this process or one of its ancestors.
    private func freeze(root: pid_t, app: pid_t, bundleID: String?) -> Bool {
        guard !isNeverFreeze(bundleID), !isFrontmost(app) else { return false }
        let tree = ProcessControl.processTree(root: root)
        let otherApps = Set(listedApps().map(\.processIdentifier)).subtracting([app])
        guard !tree.contains(where: otherApps.contains) else { return false }
        if root != app {
            guard ProcessControl.processTree(root: app).contains(root),
                  tree.allSatisfy({ label(of: $0).freezable }) else { return false }
        }
        return ProcessControl.pauseTree(root: root)
    }

    // MARK: - Actions

    func pause(_ entry: AppEntry) {
        guard let pid = entry.pid else { return }
        footprintAtPause[pid] = entry.footprint
        guard freeze(root: pid, app: pid, bundleID: entry.bundleID) else {
            footprintAtPause[pid] = nil
            notice = Notice(text: isNeverFreeze(entry.bundleID)
                ? "\(entry.name) is on the Never freeze list and was not paused."
                : isFrontmost(pid)
                ? "\(entry.name) is in use and was not paused. Switch to another app to pause it."
                : "\(entry.name) could not be paused: it has quit, another app runs inside it, or Auto Pause runs inside it.",
                isWarning: true)
            return
        }
        PausedStore.shared.add(PausedRecord(
            pid: pid, bundleID: entry.bundleID, name: entry.name, launchDate: entry.launchDate))
        refresh()
    }

    func resume(_ entry: AppEntry) {
        if entry.state == .sleeping {
            wake(entry)
            return
        }
        guard let pid = entry.pid else { return }
        thaw(pid: pid)
    }

    func deepSleep(_ entry: AppEntry) {
        guard let app = runningApp(for: entry), let pid = entry.pid else { return }
        let footprint = entry.footprint
        Task { @MainActor in
            let result = await DeepSleepController.sleep(app: app, name: entry.name, footprint: footprint)
            // `sleep` thaws the frozen subprocesses before the quit request.
            for rec in PausedStore.shared.subprocessRecords(owner: pid) where !ProcessControl.isStopped(rec.pid) {
                dropRecord(rec.pid)
            }
            switch result {
            case .slept:
                PausedStore.shared.remove(pid: pid)
                footprintAtPause[pid] = nil
            case .refused:
                // Almost always a save sheet. Freezing would leave the sheet unanswerable, so
                // the app stays running; `sleep` thawed it if it was paused.
                PausedStore.shared.remove(pid: pid)
                footprintAtPause[pid] = nil
                notice = Notice(text: "\(entry.name) did not quit (unsaved changes?) and stays open.", isWarning: true)
            case .failed(let message):
                // `sleep` may have thawed the app before the quit request failed.
                if !ProcessControl.isStopped(pid) { dropRecord(pid) }
                notice = Notice(text: "\(entry.name): \(message)", isWarning: true)
            }
            refresh()
        }
    }

    func wake(_ entry: AppEntry) {
        guard let rec = SleptStore.shared.records.first(where: { $0.bundleID == entry.id }) else { return }
        Task { @MainActor in
            if await wake(rec) { notice = nil }
            refresh()
        }
    }

    /// Relaunches one slept app, marked as waking meanwhile; a failure posts a notice.
    private func wake(_ rec: SleptRecord) async -> Bool {
        guard waking.insert(rec.bundleID).inserted else { return false }
        defer { waking.remove(rec.bundleID) }
        if case .failure(let error) = await DeepSleepController.wake(rec) {
            notice = Notice(text: "Could not wake \(rec.name): \(error.localizedDescription). It stays listed; try again.",
                            isWarning: true)
            return false
        }
        return true
    }

    func resumeAll() {
        for rec in PausedStore.shared.resumeOrder {
            // A subprocess record's pid may belong to another process by now.
            if rec.ownerPid == nil || rec.isLive { ProcessControl.resumeTree(root: rec.pid) }
            PausedStore.shared.remove(pid: rec.pid)
            footprintAtPause[rec.pid] = nil
        }
        for entry in entries where entry.state == .paused {
            if let pid = entry.pid {
                ProcessControl.resumeTree(root: pid)
                lastFrontDate[pid] = Date()
            }
        }
        rescheduleAutoPause()
        refresh()
    }

    /// Relaunches every deep-slept app. Kept apart from `resumeAll`: a relaunch is slow,
    /// brings windows to the front and takes back the memory Deep Sleep freed.
    func wakeAll() {
        let sleeping = SleptStore.shared.records
        Task { @MainActor in
            for rec in sleeping {
                _ = await wake(rec)
                refresh()
            }
        }
    }

    // MARK: - Process tree

    func toggleExpanded(_ pid: pid_t) {
        expanded.formSymmetricDifference([pid])
        refresh()
    }

    func toggleExpandedProcess(_ pid: pid_t) {
        expandedProcesses.formSymmetricDifference([pid])
    }

    /// The app's process tree with memory per node and per subtree. `apps` are the listed app
    /// pids: a subtree holding another one is not freezable.
    private func detail(for app: pid_t, apps: Set<pid_t>) -> AppDetail {
        let frozen = Set(PausedStore.shared.subprocessRecords(owner: app).map(\.pid))
        var seen: Set<pid_t> = [app]
        func build(_ pid: pid_t, _ depth: Int) -> [ProcessStat] {
            let children = ProcessControl.children(of: pid)
                .filter { seen.insert($0).inserted }
                .map { build($0, depth + 1) }
                .sorted { $0[0].subtreeResident > $1[0].subtreeResident }
            let mem = ProcessControl.memoryInfo(of: pid)
            let label = label(of: pid)
            let subtreeResident = children.reduce(mem.resident) { $0 + $1[0].subtreeResident }
            let isFrozen = frozen.contains(pid)
            let node = ProcessStat(
                pid: pid, name: label.name, role: label.role, depth: depth,
                resident: mem.resident, footprint: mem.footprint,
                subtreeResident: subtreeResident,
                subtreeFootprint: children.reduce(mem.footprint) { $0 + $1[0].subtreeFootprint },
                subtree: [pid] + children.flatMap { $0.map(\.pid) },
                stopped: ProcessControl.isStopped(pid), frozen: isFrozen,
                // Children are built first, so theirs already covers their subtrees.
                freezable: depth > 0 && label.freezable && !apps.contains(pid)
                    && children.allSatisfy { $0[0].freezable },
                reclaimed: isFrozen ? footprintAtPause[pid].map { $0 > subtreeResident ? $0 - subtreeResident : 0 } ?? 0 : 0)
            return [node] + children.flatMap { $0 }
        }
        return AppDetail(processes: build(app, 0))
    }

    private func label(of pid: pid_t) -> ProcessLabel {
        let start = ProcessControl.startTime(of: pid)
        if let cached = processLabels[pid], cached.start == start { return cached }
        // nil for processes of other users, which cannot be signalled.
        let args = AppProcesses.commandLine(of: pid)?.args
        let label = ProcessLabel(start: start, name: AppProcesses.executableName(of: pid),
                                 role: args.flatMap(AppProcesses.chromiumRole),
                                 freezable: args.map { !AppProcesses.isSharedRole($0) } ?? false)
        processLabels[pid] = label
        return label
    }

    /// Pauses one process with its subtree, recorded with its start time and the app pid.
    func pauseProcess(_ pid: pid_t, of entry: AppEntry) {
        guard let app = entry.pid, pid != app else { return }
        let name = AppProcesses.executableName(of: pid)
        let start = ProcessControl.startTime(of: pid)
        let footprint = ProcessControl.treeMemory(root: pid).footprint
        guard freeze(root: pid, app: app, bundleID: entry.bundleID) else {
            notice = Notice(text: isNeverFreeze(entry.bundleID)
                ? "\(entry.name) is on the Never freeze list; none of its processes are paused."
                : isFrontmost(app)
                ? "\(entry.name) is in use, so \(name) was not paused. Switch to another app first."
                : "\(name) could not be paused: it has quit, it or a process below it serves the whole app or is another app, or Auto Pause runs inside it.",
                isWarning: true)
            return
        }
        footprintAtPause[pid] = footprint
        PausedStore.shared.add(PausedRecord(
            pid: pid, bundleID: entry.bundleID, name: name, launchDate: start,
            ownerPid: app, kind: PausedRecord.processKind))
        if !PauseFlags.hasSeenProcessPauseNotice {
            PauseFlags.hasSeenProcessPauseNotice = true
            notice = Notice(text: "Paused \(name). If \(entry.name) stops responding, it is waiting for it: "
                + "resume it here, or switch to \(entry.name), which resumes it.")
        }
        refresh()
    }

    /// Resumes one frozen process with its subtree and drops every subprocess record in it.
    func resumeProcess(_ pid: pid_t) {
        let subtree = Set(ProcessControl.processTree(root: pid))
        for rec in PausedStore.shared.records where rec.isSubprocess && subtree.contains(rec.pid) {
            if rec.pid == pid, rec.isLive { ProcessControl.resumeTree(root: pid) }
            dropRecord(rec.pid)
        }
        refresh()
    }

    /// Resumes the app's subprocess records, children before the app.
    private func resumeSubprocesses(of owner: pid_t) {
        for rec in PausedStore.shared.subprocessRecords(owner: owner) {
            // The pid may belong to another process by now.
            if rec.isLive { ProcessControl.resumeTree(root: rec.pid) }
            dropRecord(rec.pid)
        }
    }

    /// An app quitting from the Dock or its menu may wait for a frozen helper and hang. There
    /// is no notification for another app starting to quit, but its unfrozen helpers exit at
    /// once, so the exit of an unfrozen direct child thaws the app's frozen subprocesses. A
    /// helper restarting does the same, which costs one re-freeze.
    private func syncExitWatchers() {
        // ponytail: age heuristic. Short-lived children (a git run, a terminal tab's login)
        // would thaw everything on exit; only children alive this long count as helpers. A
        // long-lived child that exits on its own still thaws; tell helpers from jobs by role
        // if that turns out to matter.
        let minAge: TimeInterval = 10
        let now = Date()
        var wanted: [pid_t: pid_t] = [:]
        for owner in Set(PausedStore.shared.records.filter(\.isSubprocess).compactMap(\.ownerPid)) {
            for child in ProcessControl.children(of: owner) where !ProcessControl.isStopped(child) {
                guard let start = ProcessControl.startTime(of: child),
                      now.timeIntervalSince(start) >= minAge else { continue }
                wanted[child] = owner
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
                    self.resumeSubprocesses(of: owner)
                    self.refresh()
                }
            }
            source.resume()
            exitWatchers[pid] = source
        }
    }
}
