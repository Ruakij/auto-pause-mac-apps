import AppKit
import Foundation

/// Whether an app will bring its windows back when relaunched, and whether we can fix it.
struct RestoreStatus {
    enum Kind {
        case good      // state restoration is on
        case fixable   // off, but we can turn it on with the user's consent
        case unknown   // handled by the app itself; we can only tell the user what to check
    }
    let kind: Kind
    let message: String
}

enum SleepResult {
    case slept(reclaimed: UInt64)
    /// The app declined to quit — almost always an unsaved-work save sheet. We never override this.
    case refused
    case failed(String)
}

/// The "Deep Sleep" tier: quit an app cleanly so macOS/the app saves its state, freeing
/// 100% of its RAM *and* swap, then relaunch later and let state restoration bring it back.
enum DeepSleepController {

    /// Browsers ignore macOS's Resume and use their own session restore.
    private static let browserPrefsPaths: [String: String] = [
        "com.google.Chrome": "Google/Chrome/Default/Preferences",
        "com.microsoft.edgemac": "Microsoft Edge/Default/Preferences",
        "com.brave.Browser": "BraveSoftware/Brave-Browser/Default/Preferences"
    ]

    private static let quitKey = "NSQuitAlwaysKeepsWindows"
    private static let modifiedListKey = "PauseModifiedRestoreFor"

    // MARK: - Preflight

    static func canRestoreState(bundleID: String?) -> RestoreStatus {
        guard let bundleID else {
            return RestoreStatus(kind: .unknown, message: "Unknown app — window restore can't be verified.")
        }

        if bundleID == "com.apple.Safari" {
            return RestoreStatus(kind: .unknown,
                message: "Safari reopens its windows using its own \"Safari opens with\" setting. Check Safari ▸ Settings ▸ General.")
        }

        if let relPath = browserPrefsPaths[bundleID] {
            let name = browserDisplayName(bundleID)
            switch browserRestoresSession(relPath: relPath) {
            case .some(true):
                return RestoreStatus(kind: .good, message: "\(name) is set to reopen your tabs on launch.")
            case .some(false):
                return RestoreStatus(kind: .unknown,
                    message: "\(name) is not set to restore tabs. Turn on Settings ▸ On startup ▸ \"Continue where you left off\" first, or your tabs won't come back.")
            case nil:
                return RestoreStatus(kind: .unknown,
                    message: "Couldn't read \(name)'s startup setting. Make sure \"Continue where you left off\" is on.")
            }
        }

        if let value = CFPreferencesCopyAppValue(quitKey as CFString, bundleID as CFString) as? Bool {
            return value
                ? RestoreStatus(kind: .good, message: "This app is set to reopen its windows after quitting.")
                : RestoreStatus(kind: .fixable, message: "This app currently closes its windows when it quits.")
        }

        // Unset means macOS's default: windows are closed on quit.
        return RestoreStatus(kind: .fixable, message: "macOS currently closes this app's windows when it quits.")
    }

    private static func browserDisplayName(_ bundleID: String) -> String {
        switch bundleID {
        case "com.google.Chrome": return "Chrome"
        case "com.microsoft.edgemac": return "Edge"
        case "com.brave.Browser": return "Brave"
        default: return "This browser"
        }
    }

    /// Chromium stores `session.restore_on_startup` in a JSON prefs file; 1 = restore last session.
    private static func browserRestoresSession(relPath: String) -> Bool? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(relPath)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = root["session"] as? [String: Any],
              let value = session["restore_on_startup"] as? Int else { return nil }
        return value == 1
    }

    /// Turn on window restore for one app. Only ever called with explicit user consent.
    static func enableStateRestoration(bundleID: String) {
        CFPreferencesSetAppValue(quitKey as CFString, true as CFBoolean, bundleID as CFString)
        CFPreferencesAppSynchronize(bundleID as CFString)

        var modified = UserDefaults.standard.stringArray(forKey: modifiedListKey) ?? []
        if !modified.contains(bundleID) {
            modified.append(bundleID)
            UserDefaults.standard.set(modified, forKey: modifiedListKey)
        }
    }

    // MARK: - Sleep / wake

    @MainActor
    static func sleep(app: NSRunningApplication, name: String, footprint: UInt64) async -> SleepResult {
        guard let bundleURL = app.bundleURL else {
            return .failed("This app has no bundle, so it can't be relaunched.")
        }
        let pid = app.processIdentifier

        // A SIGSTOP'd process can't handle the quit Apple Event, and an app waiting on a
        // frozen helper cannot quit either: thaw its frozen subprocesses and windows, then the whole tree
        // only if the app itself is frozen. A stopped job in a terminal app's tree is the
        // user's, not ours.
        let subprocesses = PausedStore.shared.partRecords(owner: pid).filter(\.isLive)
        let frozenWhole = ProcessControl.isStopped(pid) || PausedStore.shared.contains(pid: pid)
        for rec in subprocesses { ProcessControl.resumeTree(root: rec.pid) }
        if frozenWhole { ProcessControl.resumeTree(root: pid) }
        if frozenWhole || !subprocesses.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }

        guard app.terminate() else {
            return .failed("The app refused the quit request.")
        }

        let record = SleptRecord(
            bundleID: app.bundleIdentifier ?? bundleURL.path,
            bundlePath: bundleURL.path,
            name: name,
            sleptAt: Date(),
            reclaimedBytes: footprint)

        // Poll for a clean exit. Apps that autosave just save and quit; apps with a dirty
        // document put up a save sheet instead and never terminate. Big apps (browsers,
        // Electron) routinely take several seconds to shut down, so give them room before
        // concluding a sheet is up — a short window here produces false "unsaved work".
        for _ in 0..<50 { // ~10s
            try? await Task.sleep(for: .milliseconds(200))
            if app.isTerminated {
                SleptStore.shared.add(record)
                return .slept(reclaimed: footprint)
            }
        }

        // A save sheet is up and the user is deciding. If they choose Save or Don't Save,
        // the app quits after we've already given up — without this watcher it would
        // vanish from Pause with no way to wake it again.
        watchForLateTermination(app: app, record: record)
        return .refused
    }

    private static func watchForLateTermination(app: NSRunningApplication, record: SleptRecord) {
        Task { @MainActor in
            for _ in 0..<120 { // up to ~2 minutes
                try? await Task.sleep(for: .seconds(1))
                if app.isTerminated {
                    SleptStore.shared.add(record)
                    return
                }
            }
        }
    }

    /// Relaunch a sleeping app. The record is only dropped once the launch actually
    /// succeeds — dropping it on failure would erase the app from Pause entirely and
    /// leave the user with no way to bring it back.
    @MainActor
    static func wake(_ record: SleptRecord) async -> Result<Void, Error> {
        let url = URL(fileURLWithPath: record.bundlePath)

        guard FileManager.default.fileExists(atPath: record.bundlePath) else {
            SleptStore.shared.remove(bundleID: record.bundleID)
            return .failure(WakeError.bundleMissing(record.bundlePath))
        }

        // If the user already relaunched it themselves, just clear the record.
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == record.bundleID }) {
            SleptStore.shared.remove(bundleID: record.bundleID)
            return .success(())
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true // bring it back to the user, the way Resume should behave

        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            SleptStore.shared.remove(bundleID: record.bundleID)
            return .success(())
        } catch {
            // Keep the record so the row stays and the user can retry.
            return .failure(error)
        }
    }

    enum WakeError: LocalizedError {
        case bundleMissing(String)

        var errorDescription: String? {
            switch self {
            case .bundleMissing(let path):
                return "the app is no longer at \(path)"
            }
        }
    }
}
