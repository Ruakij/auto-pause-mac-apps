import Foundation
import Darwin

/// Low-level process control: tree enumeration, memory footprint, SIGSTOP/SIGCONT.
enum ProcessControl {

    /// All pids in the process tree rooted at `root` (root included), breadth-first.
    static func processTree(root: pid_t) -> [pid_t] {
        var result: [pid_t] = [root]
        var queue: [pid_t] = [root]
        var seen: Set<pid_t> = [root]
        while let pid = queue.popLast() {
            for child in children(of: pid) where !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// Direct children of a pid via proc_listchildpids, growing the buffer as needed.
    static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while true {
            var buf = [pid_t](repeating: 0, count: capacity)
            let bytes = Int32(capacity * MemoryLayout<pid_t>.size)
            let n = proc_listchildpids(pid, &buf, bytes)
            if n < 0 { return [] }
            let count = Int(n)
            if count < capacity {
                return Array(buf.prefix(count)).filter { $0 > 0 }
            }
            capacity *= 2 // buffer may have been full; retry larger
        }
    }

    /// Memory for a single process.
    ///
    /// `resident` is RAM actually held right now. `footprint` is Activity Monitor's
    /// "Memory" column, which also counts pages already compressed or swapped to disk —
    /// so footprint barely moves when a frozen app's pages are reclaimed, while resident
    /// drops sharply. Both come from one syscall.
    struct MemoryInfo {
        var resident: UInt64 = 0
        var footprint: UInt64 = 0
    }

    static func memoryInfo(of pid: pid_t) -> MemoryInfo {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard ok == 0 else { return MemoryInfo() }
        return MemoryInfo(resident: info.ri_resident_size, footprint: info.ri_phys_footprint)
    }

    /// Summed memory over the whole process tree.
    static func treeMemory(root: pid_t) -> MemoryInfo {
        processTree(root: root).reduce(into: MemoryInfo()) { acc, pid in
            let m = memoryInfo(of: pid)
            acc.resident += m.resident
            acc.footprint += m.footprint
        }
    }

    /// User + system CPU time in nanoseconds; diff two samples for a CPU percentage.
    static func cpuTimeNanos(of pid: pid_t) -> UInt64? {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard ok == 0 else { return nil }
        // ri_*_time are mach ticks, not ns (41.67 ns per tick on Apple silicon).
        let ticks = info.ri_user_time + info.ri_system_time
        return ticksToNanos.denom.dividingFullWidth(ticks.multipliedFullWidth(by: ticksToNanos.numer)).quotient
    }

    private static let ticksToNanos: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()

    /// Start time of the process; with the pid it identifies a process across pid reuse.
    static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// True if the process is currently stopped (SIGSTOP'd), via BSD process status.
    static func isStopped(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard n == size else { return false }
        return info.pbi_status == UInt32(SSTOP)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Suspend the whole tree. Parent first so it cannot spawn new children mid-freeze,
    /// then re-enumerate and stop descendants.
    ///
    /// Refuses outright if the tree contains this process. Freezing ourselves is
    /// unrecoverable: the menu bar stops responding, so nothing can be resumed, and every
    /// app frozen in the same sweep stays frozen. This check lives at the signal layer on
    /// purpose — it holds no matter what the selection logic above it decides.
    @discardableResult
    static func pauseTree(root: pid_t) -> Bool {
        guard !treeContainsSelf(root: root) else { return false }
        guard kill(root, SIGSTOP) == 0 else { return false }
        for pid in processTree(root: root) where pid != root {
            kill(pid, SIGSTOP)
        }
        return true
    }

    /// True if `root` is this process, or an ancestor of it, or otherwise has it in its tree.
    static func treeContainsSelf(root: pid_t) -> Bool {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        if root == ownPid { return true }
        if processTree(root: root).contains(ownPid) { return true }

        // Walk our own ancestry too: a shell or launcher that spawned us would take us
        // down with it, and cycles in ppid data must not hang the walk.
        var current = ownPid
        var hops = 0
        while hops < 64 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            let parent = pid_t(info.pbi_ppid)
            if parent <= 1 { break }
            if parent == root { return true }
            current = parent
            hops += 1
        }
        return false
    }

    /// Resume the whole tree except the subtrees rooted at `keepStopped`. Children first,
    /// parent last.
    @discardableResult
    static func resumeTree(root: pid_t, keepStopped: [pid_t] = []) -> Bool {
        let tree = processTree(root: root)
        let kept = Set(keepStopped.filter { $0 != root }.flatMap { processTree(root: $0) })
        for pid in tree.reversed() where pid != root && !kept.contains(pid) {
            kill(pid, SIGCONT)
        }
        return kill(root, SIGCONT) == 0
    }
}
