import Foundation

/// A kind of ongoing work that keeps an app from being paused or slept.
enum BusyCondition: String, CaseIterable, Codable {
    case cpu
    case audio
    case powerAssertion
    case debugger
    case devices
    case inputTap
    case processes

    var title: String {
        switch self {
        case .cpu: return "Computing (CPU)"
        case .audio: return "Playing or recording sound"
        case .powerAssertion: return "Keeping the Mac awake"
        case .debugger: return "Debugger attached"
        case .devices: return "Serial ports, disks, input devices"
        case .inputTap: return "Handles shortcuts or mouse gestures"
        case .processes: return "Running commands (list below)"
        }
    }
}

/// Global busy-condition preferences, stored in UserDefaults.
struct BusySettings: Equatable {
    var enabled: Set<BusyCondition> = Set(BusyCondition.allCases)
    /// Percent of one core, summed over the app tree, averaged since the previous sample.
    var cpuThresholdPercent: Double = 0.5
    /// Regexes matched against each process's full command line (argv joined by spaces).
    var patterns: [String] = BusySettings.defaultPatterns

    static let defaultPatterns = [
        #"(^|[ /])(git|ssh|scp|rsync|curl|wget|make|cargo|go|npm|pnpm|yarn|mvn|xcodebuild|docker|kubectl|terraform)( |$)"#,
        #"org\.gradle\.wrapper\.GradleWrapperMain"#,
        #"^/bin/zsh -c .*/\.claude/shell-snapshots/"#,
    ]

    /// The disabled set, so a condition added later starts enabled.
    private static let disabledKey = "PauseBusyDisabledConditions"
    private static let cpuThresholdKey = "PauseBusyCPUThresholdPercent"
    private static let patternsKey = "PauseBusyPatterns"

    /// Each value falls back to its default on its own, so adding a setting never resets the others.
    static func load(from defaults: UserDefaults = .standard) -> BusySettings {
        var s = BusySettings()
        if let raw = defaults.stringArray(forKey: disabledKey) {
            s.enabled.subtract(raw.compactMap(BusyCondition.init(rawValue:)))
        }
        if defaults.object(forKey: cpuThresholdKey) != nil {
            s.cpuThresholdPercent = defaults.double(forKey: cpuThresholdKey)
        }
        if let p = defaults.stringArray(forKey: patternsKey) {
            s.patterns = p
        }
        return s
    }

    func save(to defaults: UserDefaults = .standard) {
        let disabled = Set(BusyCondition.allCases).subtracting(enabled)
        defaults.set(disabled.map(\.rawValue).sorted(), forKey: Self.disabledKey)
        defaults.set(cpuThresholdPercent, forKey: Self.cpuThresholdKey)
        defaults.set(patterns, forKey: Self.patternsKey)
    }

    /// nil if `pattern` compiles, else a short message for the settings UI.
    static func patternError(_ pattern: String) -> String? {
        if pattern.isEmpty { return "Empty pattern" }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return "Invalid regular expression"
        }
    }
}
