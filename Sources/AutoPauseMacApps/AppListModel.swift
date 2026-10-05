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

    var canDeepSleep: Bool { state != .sleeping }
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
        rescheduleAutoPause()
        refresh()
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
        cancelAutoPause(pid)
    }

    /// The idle clock starts when an app leaves the front, not when it came there.
    private func didDeactivate(pid: pid_t) {
        if frontPid == pid { frontPid = nil }
        lastFrontDate[pid] = Date()
        scheduleAutoPause(pid)
    }

    func startRefreshing() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    func runningApp(for entry: AppEntry) -> NSRunningApplication? {
        guard let pid = entry.pid else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    private func listedApps() -> [NSRunningApplication] {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier != ownPid
                && $0.bundleIdentifier != "com.apple.finder"
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
                history: history[pid] ?? []
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
            guard entry.state == .running, let pid = entry.pid else { return false }
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
            guard ProcessControl.pauseTree(root: pid) else {
                skipped.append(entry.name)   // refused, e.g. it would have frozen us
                continue
            }
            PausedStore.shared.add(PausedRecord(
                pid: pid, bundleID: entry.bundleID, name: entry.name, launchDate: entry.launchDate))
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
            ProcessControl.resumeTree(root: pid)
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
        guard let app = app ?? NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
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
                ? await busy.findings(roots: [pid], settings: settings, waitForCPU: false)[0] : []
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
            guard ProcessControl.pauseTree(root: pid) else { return }
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

    // MARK: - Actions

    func pause(_ entry: AppEntry) {
        guard let pid = entry.pid else { return }
        footprintAtPause[pid] = entry.footprint
        guard ProcessControl.pauseTree(root: pid) else { return }
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
                // Almost always an unsaved-work save sheet. Leave it frozen instead.
                notice = "\(entry.name) has unsaved work, so it was left frozen instead of quit."
                footprintAtPause[pid] = footprint
                ProcessControl.pauseTree(root: pid)
                PausedStore.shared.add(PausedRecord(
                    pid: pid, bundleID: entry.bundleID, name: entry.name, launchDate: entry.launchDate))
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
        let sleeping = SleptStore.shared.records
        Task { @MainActor in
            for rec in sleeping { _ = await DeepSleepController.wake(rec) }
            refresh()
        }
        refresh()
    }
}
