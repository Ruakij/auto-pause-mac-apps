import Foundation
import Darwin

/// One process of an app's tree, labelled for display. View-only: nothing here freezes.
struct AppProcess: Equatable {
    let pid: pid_t
    let ppid: pid_t
    /// Executable name, e.g. "Code Helper (Renderer)".
    let name: String
    /// Chromium/Electron role from `--type` / `--utility-sub-type` ("renderer", "gpu-process",
    /// "NetworkService"), "main" for the app process, nil for plain children.
    let role: String?
    /// Serves the whole app (main, GPU, network/audio/storage services), so never part of a
    /// per-window group.
    let isShared: Bool
}

/// Process tree of any app with role labels, plus command line, environment and CPU time.
enum AppProcesses {

    /// The tree rooted at the app's pid, root first.
    static func list(appPid: pid_t) -> [AppProcess] {
        ProcessControl.processTree(root: appPid).map { pid in
            let args = commandLine(of: pid)?.args ?? []
            let role = pid == appPid ? "main" : chromiumRole(args)
            return AppProcess(
                pid: pid,
                ppid: parentPid(of: pid),
                name: executableName(of: pid),
                role: role,
                isShared: pid == appPid || isSharedRole(args)
            )
        }
    }

    static func executableName(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
        return (String(cString: buf) as NSString).lastPathComponent
    }

    static func parentPid(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }

    /// argv and environment of a same-user process (KERN_PROCARGS2); nil for other users.
    static func commandLine(of pid: pid_t) -> (args: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        // Layout: argc, exec path, NUL padding, argc args, env strings, empty string.
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var strings: [String] = []
        while i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if i == start && strings.count >= argc { break }
            strings.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        var env: [String: String] = [:]
        for entry in strings.dropFirst(argc) {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return (Array(strings.prefix(argc)), env)
    }

    static func flag(_ name: String, in args: [String]) -> String? {
        let prefix = "--\(name)="
        return args.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private static func chromiumRole(_ args: [String]) -> String? {
        guard let type = flag("type", in: args) else { return nil }
        if type == "utility", let sub = flag("utility-sub-type", in: args) {
            return sub.split(separator: ".").last.map(String.init) ?? sub
        }
        return type
    }

    /// Electron's `utilityProcess` runs app code as `node.mojom.NodeService` (VS Code's extension
    /// host, file watcher, ptyHost), which may well be per window, so only Chromium's own
    /// services count as shared.
    private static func isSharedRole(_ args: [String]) -> Bool {
        switch flag("type", in: args) {
        case "gpu-process", "zygote", "broker", "crashpad-handler": return true
        case "utility": return flag("utility-sub-type", in: args) != "node.mojom.NodeService"
        default: return false
        }
    }
}
