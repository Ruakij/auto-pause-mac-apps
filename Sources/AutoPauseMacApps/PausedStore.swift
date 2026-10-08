import Foundation

/// Persists which apps and processes are paused so a crash of Pause never strands frozen
/// processes. A whole-app record holds the app pid. A subprocess record (`kind` "process") holds
/// the root of a subtree frozen on its own, with `ownerPid` the app's pid. Records with
/// `ownerPid` and any other `kind` (none: window records of older builds; an unknown one: a
/// newer build) are only decoded, resumed at launch and dropped
/// (`AppListModel.resumeForeignRecords`).
struct PausedRecord: Codable, Equatable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    /// App launch date, or the start time of the process for subprocess and window records:
    /// with the pid it guards against pid reuse.
    let launchDate: Date?
    /// The app's main pid for subprocess and window records; nil for a whole-app record.
    var ownerPid: pid_t? = nil
    /// "process" for a subprocess record; nil for whole-app and old window records, anything
    /// else for records of a newer build.
    var kind: String? = nil

    static let processKind = "process"

    var isSubprocess: Bool { ownerPid != nil && kind == Self.processKind }
    /// A record with an owner this build cannot handle: an old window record or an unknown kind.
    var isForeign: Bool { ownerPid != nil && !isSubprocess }

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
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? kind
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

    /// Subprocess records of this app.
    func subprocessRecords(owner: pid_t) -> [PausedRecord] {
        records.filter { $0.isSubprocess && $0.ownerPid == owner }
    }

    /// Records with an owner before whole-app records: a subprocess is a child of its app, and
    /// children resume first.
    var resumeOrder: [PausedRecord] {
        records.filter { $0.ownerPid != nil } + records.filter { $0.ownerPid == nil }
    }

    /// Drop records whose process is gone or was replaced (pid reuse guard via launch date).
    /// A subprocess record stays while its process lives in its app's tree. One that left the
    /// tree (reparented to launchd after the app quit) or whose app is gone is resumed first:
    /// nothing else would ever wake it.
    func pruneStale(currentApps: [(pid: pid_t, launchDate: Date?)]) {
        let live = Dictionary(uniqueKeysWithValues: currentApps.map { ($0.pid, $0.launchDate) })
        var trees: [pid_t: Set<pid_t>] = [:]
        records.removeAll { rec in
            if let owner = rec.ownerPid {
                guard rec.isLive else { return true }
                if live[owner] != nil {
                    if trees[owner] == nil { trees[owner] = Set(ProcessControl.processTree(root: owner)) }
                    if trees[owner]!.contains(rec.pid) { return false }
                }
                ProcessControl.resumeTree(root: rec.pid)
                return true
            }
            guard let launch = live[rec.pid] else { return true } // process gone
            if let recDate = rec.launchDate, let nowDate = launch ?? nil {
                return abs(recDate.timeIntervalSince(nowDate)) > 2 // different process reusing pid
            }
            return false
        }
        save()
    }
}
