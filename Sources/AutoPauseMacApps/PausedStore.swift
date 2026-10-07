import Foundation

/// Persists which apps are paused so a crash of Pause never strands frozen processes.
/// Records with `ownerPid` set are window records of builds that froze single windows; they are
/// only decoded, resumed at launch and dropped (`AppListModel.resumeWindowRecords`).
struct PausedRecord: Codable, Equatable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    /// App launch date, or the start time of the process for window records: with the pid it
    /// guards against pid reuse.
    let launchDate: Date?
    /// The app's main pid for window records; nil for a whole-app record.
    var ownerPid: pid_t? = nil

    /// Still the process this record was made for.
    var isLive: Bool {
        guard let start = ProcessControl.startTime(of: pid) else { return false }
        return launchDate.map { abs($0.timeIntervalSince(start)) <= 2 } ?? true
    }
}

extension PausedRecord {
    // The synthesized decoder throws on a missing key, which would drop paused.json written
    // before window records existed and strand the apps it lists.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(pid: try c.decode(pid_t.self, forKey: .pid),
                  bundleID: try c.decodeIfPresent(String.self, forKey: .bundleID),
                  name: try c.decode(String.self, forKey: .name),
                  launchDate: try c.decodeIfPresent(Date.self, forKey: .launchDate))
        ownerPid = try c.decodeIfPresent(pid_t.self, forKey: .ownerPid) ?? ownerPid
    }
}

final class PausedStore {
    static let shared = PausedStore()

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Directory name intentionally stays "Pause" across the rename to
            // "Auto Pause Mac Apps": changing it would orphan existing records and
            // strand apps that are currently frozen on users' machines.
            .appendingPathComponent("Pause", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("paused.json")
    }()

    private(set) var records: [PausedRecord] = []

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PausedRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func add(_ record: PausedRecord) {
        records.removeAll { $0.pid == record.pid }
        records.append(record)
        save()
    }

    func remove(pid: pid_t) {
        records.removeAll { $0.pid == pid }
        save()
    }

    /// True for a whole-app record of this pid.
    func contains(pid: pid_t) -> Bool {
        records.contains { $0.pid == pid && $0.ownerPid == nil }
    }

    /// Drop records whose process is gone or was replaced (pid reuse guard via launch date).
    func pruneStale(currentApps: [(pid: pid_t, launchDate: Date?)]) {
        let live = Dictionary(uniqueKeysWithValues: currentApps.map { ($0.pid, $0.launchDate) })
        records.removeAll { rec in
            guard let launch = live[rec.pid] else { return true } // process gone
            if let recDate = rec.launchDate, let nowDate = launch ?? nil {
                return abs(recDate.timeIntervalSince(nowDate)) > 2 // different process reusing pid
            }
            return false
        }
        save()
    }
}
