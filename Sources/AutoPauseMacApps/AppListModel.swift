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

    var canDeepSleep: Bool { state != .sleeping }
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
    /// just deactivated can still read true. Published because rows disable Pause for it.
    @Published private(set) var frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    private var observers: [NSObjectProtocol] = []

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
        resumeWindowRecords()
        rescheduleAutoPause()
        refresh()
    }

    /// Window records (`ownerPid` set) come from builds that froze single windows. Nothing
    /// else would ever wake them, so they are resumed and dropped before the first refresh.
    private func resumeWindowRecords() {
        for rec in PausedStore.shared.records {
            guard let owner = rec.ownerPid else { continue }
            // A window of an app frozen whole resumes with the app; the pid may belong to
            // another process by now.
            let ownerFrozen = PausedStore.shared.contains(pid: owner) && ProcessControl.isStopped(owner)
            if !ownerFrozen, rec.isLive { ProcessControl.resumeTree(root: rec.pid) }
            PausedStore.shared.remove(pid: rec.pid)
        }
    }

    /// The activation notification arrives while a frozen app is still stopped, so thawing
    /// here is what lets a Dock click or Cmd-Tab bring it back. Applies to every frozen app,
    /// however it was frozen.
    private func didActivate(pid: pid_t) {
        frontPid = pid
        if ProcessControl.isStopped(pid) || PausedStore.shared.contains(pid: pid) {
            ProcessControl.resumeTree(root: pid)
            PausedStore.shared.remove(pid: pid)
            footprintAtPause[pid] = nil
            reclaimSession.removeAll { $0 == pid }
            lastFrontDate[pid] = Date()
            refresh()
        } else {
            lastFrontDate[pid] = Date()
        }
        // Cancels the timer of the frontmost app.
        scheduleAutoPause(pid)
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
            guard freeze(root: pid, bundleID: entry.bundleID) else {
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
            guard freeze(root: pid, bundleID: app.bundleIdentifier) else { return }
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
    /// yields no state for most rows; the next one, 3 s later, does. Never-freeze apps and
    /// frozen apps get no state.
    private func startLivePass(_ apps: [NSRunningApplication]) {
        guard timer != nil, livePass == nil else { return }
        let roots = apps.filter { !isNeverFreeze($0.bundleIdentifier) }.map(\.processIdentifier)
            .filter { !ProcessControl.isStopped($0) && !PausedStore.shared.contains(pid: $0) }
        let generation = livePassGeneration
        let settings = busySettings
        livePass = Task { @MainActor in
            let results = await busy.findings(roots: roots, settings: settings, waitForCPU: false)
            livePass = nil
            guard generation == livePassGeneration else { return }
            var newApps: [pid_t: LiveState] = [:]
            for (pid, found) in zip(roots, results) {
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

    /// The one place anything is frozen: a manual Pause, auto-pause and Free Up Memory.
    /// Apps on the Never freeze list and the frontmost app are refused here, with no Force:
    /// activating a frozen app is what thaws it, and the frontmost app gets no activation when
    /// clicked, so it would stay frozen. `pauseTree` keeps its own guard against freezing this
    /// process.
    private func freeze(root: pid_t, bundleID: String?) -> Bool {
        guard !isNeverFreeze(bundleID), !isFrontmost(root) else { return false }
        return ProcessControl.pauseTree(root: root)
    }

    // MARK: - Actions

    func pause(_ entry: AppEntry) {
        guard let pid = entry.pid else { return }
        footprintAtPause[pid] = entry.footprint
        guard freeze(root: pid, bundleID: entry.bundleID) else {
            footprintAtPause[pid] = nil
            notice = Notice(text: isNeverFreeze(entry.bundleID)
                ? "\(entry.name) is on the Never freeze list and was not paused."
                : isFrontmost(pid)
                ? "\(entry.name) is in use and was not paused. Switch to another app to pause it."
                : "\(entry.name) could not be paused: it has quit, or Auto Pause runs inside it.",
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
        ProcessControl.resumeTree(root: pid)
        PausedStore.shared.remove(pid: pid)
        footprintAtPause[pid] = nil
        lastFrontDate[pid] = Date()
        scheduleAutoPause(pid)
        refresh()
    }

    func deepSleep(_ entry: AppEntry) {
        guard let app = runningApp(for: entry), let pid = entry.pid else { return }
        let footprint = entry.footprint
        Task { @MainActor in
            let result = await DeepSleepController.sleep(app: app, name: entry.name, footprint: footprint)
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
        for rec in PausedStore.shared.records {
            ProcessControl.resumeTree(root: rec.pid)
            PausedStore.shared.remove(pid: rec.pid)
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
}
