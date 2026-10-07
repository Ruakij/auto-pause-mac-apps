import Foundation

/// Per-app preferences (currently: idle-based auto-pause), keyed by bundle identifier.
struct AppSettings: Codable, Equatable {
    var bundleID: String
    var autoPauseEnabled: Bool = false
    var autoPauseMinutes: Int = 10
    /// Read only to migrate old files into the Never freeze list; see `takeExcludedFromReclaim`.
    var excludedFromReclaim: Bool = false
}

extension AppSettings {
    // The synthesized decoder ignores property defaults and throws on a missing key, which
    // drops the whole settings file whenever a field is added. Every field but bundleID
    // falls back to the property default above.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(bundleID: try c.decode(String.self, forKey: .bundleID))
        autoPauseEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoPauseEnabled) ?? autoPauseEnabled
        autoPauseMinutes = try c.decodeIfPresent(Int.self, forKey: .autoPauseMinutes) ?? autoPauseMinutes
        excludedFromReclaim = try c.decodeIfPresent(Bool.self, forKey: .excludedFromReclaim) ?? excludedFromReclaim
    }
}

/// Global, one-off flags.
enum PauseFlags {
    private static let seenDeepSleepWarningKey = "PauseHasSeenDeepSleepWarning"
    private static let completedOnboardingKey = "PauseHasCompletedOnboarding"

    static var hasSeenDeepSleepWarning: Bool {
        get { UserDefaults.standard.bool(forKey: seenDeepSleepWarningKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenDeepSleepWarningKey) }
    }

    static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: completedOnboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: completedOnboardingKey) }
    }
}

final class AppSettingsStore {
    static let shared = AppSettingsStore()

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Directory name intentionally stays "Pause" across the rename to
            // "Auto Pause Mac Apps": changing it would orphan existing records and
            // strand apps that are currently frozen on users' machines.
            .appendingPathComponent("Pause", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    private var byBundle: [String: AppSettings] = [:]

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AppSettings].self, from: data) else { return }
        byBundle = Dictionary(uniqueKeysWithValues: decoded.map { ($0.bundleID, $0) })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(byBundle.values)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func settings(for bundleID: String?) -> AppSettings {
        guard let id = bundleID, let existing = byBundle[id] else {
            return AppSettings(bundleID: bundleID ?? "")
        }
        return existing
    }

    /// Bundle IDs still flagged by the old Free Up Memory opt-out, flags cleared and saved.
    func takeExcludedFromReclaim() -> [String] {
        let ids = byBundle.values.filter(\.excludedFromReclaim).map(\.bundleID).sorted()
        guard !ids.isEmpty else { return [] }
        for id in ids { byBundle[id]?.excludedFromReclaim = false }
        save()
        return ids
    }

    func update(_ settings: AppSettings) {
        guard !settings.bundleID.isEmpty else { return }
        byBundle[settings.bundleID] = settings
        save()
    }
}
