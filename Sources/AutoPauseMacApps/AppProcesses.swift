import Foundation
import Darwin

/// Labels for the processes of an app's tree: executable name, Chromium/Electron role, command
/// line and chosen environment variables. View-only: nothing here freezes.
enum AppProcesses {

    static func executableName(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
        return (String(cString: buf) as NSString).lastPathComponent
    }

    /// argv of a same-user process (KERN_PROCARGS2) and the values of the environment variables
    /// named in `envKeys`; nil for other users. The rest of the environment is skipped, not kept.
    static func commandLine(of pid: pid_t, envKeys: Set<String> = []) -> (args: [String], env: [String: String])? {
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
        var args: [String] = []
        var env: [String: String] = [:]
        while i < size, args.count < argc || !envKeys.isEmpty {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            let entry = buf[start..<i]
            i += 1
            if args.count < argc {
                args.append(String(decoding: entry, as: UTF8.self))
                continue
            }
            guard !entry.isEmpty else { break }
            // Only the key is decoded before the check, so no other value is ever a string.
            guard let eq = entry.firstIndex(of: UInt8(ascii: "=")),
                  envKeys.contains(String(decoding: entry[..<eq], as: UTF8.self)) else { continue }
            env[String(decoding: entry[..<eq], as: UTF8.self)] = String(decoding: entry[(eq + 1)...], as: UTF8.self)
        }
        return (args, env)
    }

    static func flag(_ name: String, in args: [String]) -> String? {
        let prefix = "--\(name)="
        return args.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// Chromium/Electron role from `--type` / `--utility-sub-type` ("renderer", "gpu-process",
    /// "NetworkService"); nil for plain processes.
    static func chromiumRole(_ args: [String]) -> String? {
        guard let type = flag("type", in: args) else { return nil }
        if type == "utility", let sub = flag("utility-sub-type", in: args) {
            return sub.split(separator: ".").last.map(String.init) ?? sub
        }
        return type
    }

    /// A Chromium service that serves the whole app (GPU, network, storage, audio, zygote,
    /// broker, crashpad): freezing it stalls every window. Electron's `utilityProcess` runs app
    /// code as `node.mojom.NodeService` (VS Code's extension host, file watcher, ptyHost),
    /// which may well be per window, so only Chromium's own services count as shared.
    static func isSharedRole(_ args: [String]) -> Bool {
        switch flag("type", in: args) {
        case "gpu-process", "zygote", "broker", "crashpad-handler": return true
        case "utility": return flag("utility-sub-type", in: args) != "node.mojom.NodeService"
        default: return false
        }
    }
}
