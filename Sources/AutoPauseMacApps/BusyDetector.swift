import Foundation
import Darwin
import CoreAudio
import CoreGraphics
import CoreMediaIO
import IOKit
import IOKit.pwr_mgt

/// One reason a process tree counts as busy.
struct BusyFinding: Equatable {
    var condition: BusyCondition
    var pid: pid_t
    /// Short user-facing text, e.g. "git fetch", "playing audio", "CPU 35%".
    var detail: String
}

/// Evaluates busy conditions over a set of pids. Stateful (unlike `ProcessControl`): it keeps
/// the previous CPU sample per pid so a re-check measures CPU since the previous check.
/// Not thread-safe; call from one actor.
final class BusyDetector {

    private struct CPUSample {
        var cpuNanos: UInt64
        var uptimeNanos: UInt64
    }

    private var cpuSamples: [pid_t: CPUSample] = [:]
    private var compiled: (patterns: [String], regexes: [NSRegularExpression]) = ([], [])

    /// Older samples average over too long a window to say anything about now. Above the
    /// auto-pause re-check intervals (30 s and 60 s, plus timer tolerance), so a re-check
    /// measures against the sample of the previous one.
    private let maxSampleAge: UInt64 = 120 * NSEC_PER_SEC

    /// One result per tree. System-wide lists (audio objects, power assertions, the IORegistry)
    /// are read once for all trees, and the CPU wait for missing samples happens at most once.
    /// Without `waitForCPU`, a tree with no recent CPU sample at all is only sampled and its
    /// result is nil: the caller checks again later, and that check measures over the gap.
    func findings(forTrees trees: [[pid_t]], settings: BusySettings, waitForCPU: Bool = true) -> [[BusyFinding]?] {
        let on = settings.enabled
        let pids = trees.flatMap { $0 }
        let pidSet = Set(pids)
        var shared: [BusyFinding] = []
        if on.contains(.audio) { shared += audioFindings(pidSet) }
        if on.contains(.powerAssertion) { shared += powerAssertionFindings(pidSet) }
        if on.contains(.debugger) {
            shared += pids.filter { Self.bsdInfo($0).map { $0.pbi_flags & UInt32(PROC_FLAG_TRACED) != 0 } ?? false }
                .map { BusyFinding(condition: .debugger, pid: $0, detail: "debugger attached") }
        }
        if on.contains(.devices) { shared += deviceFindings(pids) + hidFindings(pidSet) }
        if on.contains(.inputTap) { shared += inputTapFindings(pidSet) }
        if on.contains(.processes) { shared += processFindings(pids, patterns: settings.patterns) }

        let primed = on.contains(.cpu) ? primeCPU(pids, wait: waitForCPU) : []
        return trees.map { tree in
            let members = Set(tree)
            var result: [BusyFinding] = []
            if on.contains(.cpu) {
                if !waitForCPU, !members.isEmpty, members.isSubset(of: primed) { return nil }
                // Unless waited for, a pid sampled just now has no interval to measure yet.
                let measured = waitForCPU ? tree : tree.filter { !primed.contains($0) }
                if let f = cpuFinding(measured, thresholdPercent: settings.cpuThresholdPercent) { result.append(f) }
            }
            return result + shared.filter { members.contains($0.pid) }
        }
    }

    // MARK: CPU

    /// Takes a first sample for every pid without a recent one and returns those pids. With
    /// `wait` (a manual click, no earlier sample) a short second sample still gives an answer.
    private func primeCPU(_ pids: [pid_t], wait: Bool) -> Set<pid_t> {
        let now = DispatchTime.now().uptimeNanoseconds
        cpuSamples = cpuSamples.filter { now - $0.value.uptimeNanos < maxSampleAge }
        var added: Set<pid_t> = []
        for pid in pids where cpuSamples[pid] == nil {
            if let s = Self.cpuSample(pid) {
                cpuSamples[pid] = s
                added.insert(pid)
            }
        }
        if wait, !added.isEmpty { Thread.sleep(forTimeInterval: 0.2) }
        return added
    }

    /// One finding for the whole tree, attributed to its busiest pid: the threshold is for the
    /// app, and many helpers each just under it still add up to an app at work.
    private func cpuFinding(_ pids: [pid_t], thresholdPercent: Double) -> BusyFinding? {
        var totalPercent = 0.0
        var busiest: (pid: pid_t, percent: Double)?
        for pid in pids {
            guard let cur = Self.cpuSample(pid) else { cpuSamples[pid] = nil; continue }
            defer { cpuSamples[pid] = cur }
            guard let prev = cpuSamples[pid],
                  cur.cpuNanos >= prev.cpuNanos, cur.uptimeNanos > prev.uptimeNanos else { continue }
            let percent = Double(cur.cpuNanos - prev.cpuNanos) / Double(cur.uptimeNanos - prev.uptimeNanos) * 100
            totalPercent += percent
            if percent > busiest?.percent ?? -1 { busiest = (pid, percent) }
        }
        guard let top = busiest, totalPercent >= thresholdPercent else { return nil }
        let shown = totalPercent >= 10 ? String(format: "%.0f", totalPercent) : String(format: "%.1f", totalPercent)
        return BusyFinding(condition: .cpu, pid: top.pid, detail: "CPU \(shown)%")
    }

    private static func cpuSample(_ pid: pid_t) -> CPUSample? {
        ProcessControl.cpuTimeNanos(of: pid).map { CPUSample(cpuNanos: $0, uptimeNanos: DispatchTime.now().uptimeNanoseconds) }
    }

    // MARK: Audio

    private func audioFindings(_ pids: Set<pid_t>) -> [BusyFinding] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let objects: [AudioObjectID] = Self.audioArray(system, kAudioHardwarePropertyProcessObjectList)
        var result: [BusyFinding] = []
        for obj in objects {
            guard let pid: pid_t = Self.audioValue(obj, kAudioProcessPropertyPID), pids.contains(pid) else { continue }
            let output = (Self.audioValue(obj, kAudioProcessPropertyIsRunningOutput) as UInt32?) ?? 0 != 0
            let input = (Self.audioValue(obj, kAudioProcessPropertyIsRunningInput) as UInt32?) ?? 0 != 0
            if input {
                result.append(BusyFinding(condition: .audio, pid: pid, detail: "using the microphone"))
            } else if output {
                result.append(BusyFinding(condition: .audio, pid: pid, detail: "playing audio"))
            }
        }
        return result
    }

    private static func audioAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func audioValue<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = audioAddress(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return ptr.load(as: T.self)
    }

    private static func audioArray<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var addr = audioAddress(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(size) / MemoryLayout<T>.stride))
    }

    // MARK: Power assertions

    private func powerAssertionFindings(_ pids: Set<pid_t>) -> [BusyFinding] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var result: [BusyFinding] = []
        var seen: Set<pid_t> = []
        for (holder, assertions) in byProcess {
            for a in assertions {
                // Audio assertions are held by coreaudiod on behalf of the playing app.
                let owner = (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? holder.int32Value
                guard pids.contains(owner), !seen.contains(owner) else { continue }
                seen.insert(owner)
                let name = (a["AssertName"] as? String).map { ": \($0.prefix(40))" } ?? ""
                result.append(BusyFinding(condition: .powerAssertion, pid: owner, detail: "keeping the Mac awake\(name)"))
            }
        }
        return result
    }

    // MARK: Debugger and BSD info

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    // MARK: Devices

    private func deviceFindings(_ pids: [pid_t]) -> [BusyFinding] {
        var result: [BusyFinding] = []
        for pid in pids {
            if let path = Self.openDevicePaths(pid).first {
                result.append(BusyFinding(condition: .devices, pid: pid, detail: "using \(path)"))
            }
        }
        return result
    }

    private static func isDevicePath(_ path: String) -> Bool {
        if path.hasPrefix("/dev/cu.") || path.hasPrefix("/dev/tty.") || path.hasPrefix("/dev/disk") { return true }
        return false // /dev/tty, /dev/ttys*, /dev/ptmx: every terminal has them
    }

    private static func openDevicePaths(_ pid: pid_t) -> [String] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vinfo = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vinfo, size) == size else { continue }
            let path = withUnsafeBytes(of: vinfo.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if isDevicePath(path) { paths.append(path) }
        }
        return paths
    }

    private func hidFindings(_ pids: Set<pid_t>) -> [BusyFinding] {
        // User clients are never registered, so service matching misses them: walk the plane.
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                       &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [BusyFinding] = []
        var seen: Set<pid_t> = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard IOObjectConformsTo(entry, "IOHIDLibUserClient") != 0 else { continue }
            // "pid 123, name"
            guard let creator = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  creator.hasPrefix("pid "),
                  let pid = pid_t(creator.dropFirst(4).prefix { $0.isNumber }),
                  pids.contains(pid), !seen.contains(pid) else { continue }
            seen.insert(pid)
            result.append(BusyFinding(condition: .devices, pid: pid, detail: "using an input device"))
        }
        return result
    }

    // MARK: Input taps

    /// Active (not listen-only) event taps can swallow or rewrite keystrokes and clicks; a
    /// frozen one stalls that input for the whole session until the tap times out.
    private func inputTapFindings(_ pids: Set<pid_t>) -> [BusyFinding] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return [] }
        var seen: Set<pid_t> = []
        return taps.prefix(Int(count)).compactMap { tap in
            guard tap.enabled, tap.options != .listenOnly,
                  pids.contains(tap.tappingProcess), seen.insert(tap.tappingProcess).inserted else { return nil }
            return BusyFinding(condition: .inputTap, pid: tap.tappingProcess, detail: "handles shortcuts or mouse gestures")
        }
    }

    // MARK: Processes

    private func regexes(for patterns: [String]) -> [NSRegularExpression] {
        if compiled.patterns != patterns {
            // Invalid patterns are rejected at entry; any that slip through are skipped.
            compiled = (patterns, patterns.compactMap { try? NSRegularExpression(pattern: $0) })
        }
        return compiled.regexes
    }

    private func processFindings(_ pids: [pid_t], patterns: [String]) -> [BusyFinding] {
        let regexes = regexes(for: patterns)
        guard !regexes.isEmpty else { return [] }
        var result: [BusyFinding] = []
        for pid in pids {
            guard let argv = Self.arguments(pid) else { continue }
            let line = argv.joined(separator: " ")
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regexes.lazy.compactMap({ $0.firstMatch(in: line, range: range) }).first,
                  let matched = Range(match.range, in: line) else { continue }
            result.append(BusyFinding(condition: .processes, pid: pid,
                                      detail: Self.label(argv: argv, line: line, matched: matched, pid: pid, pids: pids)))
        }
        return result
    }

    /// Short name for a matched command: "git fetch", "npm run", "running command (sleep)".
    private static func label(argv: [String], line: String, matched: Range<String.Index>,
                              pid: pid_t, pids: [pid_t]) -> String {
        let argv0 = (argv.first.map { ($0 as NSString).lastPathComponent }) ?? "process"
        // A `shell -c` line is unreadable; its child says what actually runs.
        if ["sh", "bash", "zsh"].contains(argv0), argv.dropFirst().first == "-c" {
            let child = pids.first { $0 != pid && bsdInfo($0)?.pbi_ppid == UInt32(pid) }
            let childName = child.flatMap { arguments($0)?.first.map { ($0 as NSString).lastPathComponent } ?? name($0) }
            return childName.map { "running command (\($0))" } ?? "running command"
        }
        let token = line[matched].trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let tool = (token as NSString).lastPathComponent
        guard !tool.isEmpty, tool.count <= 20, !tool.contains(" ") else { return argv0 }
        let next = line[matched.upperBound...].split(separator: " ").first.map(String.init)
        if let next, !next.hasPrefix("-"), !next.contains("/"), next.count <= 20 {
            return "\(tool) \(next)"
        }
        return tool
    }

    private static func name(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// argv via KERN_PROCARGS2; works for own-uid processes without privileges.
    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        // Layout: argc, exec path, NUL padding, argv[0..argc), env...
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args.isEmpty ? nil : args
    }

    // MARK: System-wide gates

    /// Reasons that block every automatic pause, with no app to attribute them to.
    static func systemBlockers() -> [String] {
        var reasons: [String] = []
        if cameraRunning() { reasons.append("camera in use") }
        let names = Set(allPids().compactMap(name))
        if names.contains("screensharingd") { reasons.append("screen sharing active") }
        if names.contains("SidecarRelay") { reasons.append("Sidecar active") }
        return reasons
    }

    private static func cameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == 0 else { return false }
        addr.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for device in devices.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size) {
            var running: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == 0,
               running != 0 { return true }
        }
        return false
    }

    private static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return Array(buf.prefix(max(0, Int(n)))).filter { $0 > 0 }
    }
}

extension Array where Element == BusyFinding {
    /// "git fetch, playing audio": each detail once, in finding order.
    var summary: String {
        var seen: Set<String> = []
        return map(\.detail).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
}

/// Owns the `BusyDetector` on one serial queue: the detector is not thread-safe, and a
/// first CPU sample blocks its caller for 200 ms, which must not be the main thread.
final class BusyEvaluator: @unchecked Sendable {
    private let detector = BusyDetector()
    private let queue = DispatchQueue(label: "BusyEvaluator", qos: .utility)

    /// Findings per app tree, in the order of `roots`; nil only without `waitForCPU`, see
    /// `BusyDetector.findings(forTrees:settings:waitForCPU:)`.
    func findings(roots: [pid_t], settings: BusySettings, waitForCPU: Bool = true) async -> [[BusyFinding]?] {
        await withCheckedContinuation { cont in
            queue.async {
                let trees = roots.map { ProcessControl.processTree(root: $0) }
                cont.resume(returning: self.detector.findings(forTrees: trees, settings: settings, waitForCPU: waitForCPU))
            }
        }
    }

    /// Findings over exactly these pids, e.g. one window group, as one tree.
    func findings(pids: [pid_t], settings: BusySettings, waitForCPU: Bool = true) async -> [BusyFinding]? {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: self.detector.findings(forTrees: [pids], settings: settings, waitForCPU: waitForCPU)[0])
            }
        }
    }

    func systemBlockers() async -> [String] {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: BusyDetector.systemBlockers()) }
        }
    }
}
