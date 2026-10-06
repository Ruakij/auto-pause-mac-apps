import AppKit
import Darwin

/// The processes that belong to one window of an app, frozen together.
struct WindowGroup: Equatable {
    /// App-specific window id (VS Code's window number).
    let id: Int
    var title: String?
    /// The processes that define the window, by role ("renderer", "extension host",
    /// "file watcher"). A role is missing when it could not be identified.
    var anchors: [String: pid_t]
    /// Everything frozen with the window: the anchors and their descendants.
    var pids: Set<pid_t>
}

struct WindowMapping: Equatable {
    enum Source { case statusCommand, processScan }
    var groups: [WindowGroup]
    /// Processes of the app tree outside every group (main, GPU, utility services, ptyHost and
    /// its shells, renderers without a window). Never frozen per window.
    var shared: [pid_t]
    var source: Source
}

/// Per-window grouping for apps with a verified process-to-window mapping. Every other app
/// (AppKit apps, Chromium browsers, untested Electron apps) gets nil and is shown ungrouped.
enum WindowGroups {

    static func isSupported(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(VSCodeWindows.bundleIds.contains) ?? false
    }

    static func mapping(for app: NSRunningApplication) async -> WindowMapping? {
        guard let id = app.bundleIdentifier, VSCodeWindows.bundleIds.contains(id),
              let executable = app.executableURL, let bundle = app.bundleURL else { return nil }
        return await VSCodeWindows.mapping(mainPid: app.processIdentifier, executable: executable, bundle: bundle)
    }

    /// The group whose window has this AX title, or nil when none or several match.
    ///
    /// Titles are compared whole first, then without the first segment: a mapping is a
    /// snapshot, and the first segment is VS Code's active editor, which changes whenever the
    /// user switches files, while the rest (folder, profile) stays. A frozen renderer cannot
    /// retitle its window, so the AX title of a frozen window is its title at freeze time.
    static func match(axTitle: String, in groups: [WindowGroup]) -> WindowGroup? {
        let wanted = normalizedSegments(axTitle)
        guard !wanted.isEmpty else { return nil }
        let titled = groups.compactMap { g in g.title.map { (g, normalizedSegments($0)) } }
        let exact = titled.filter { $0.1 == wanted }
        if exact.count == 1 { return exact[0].0 }
        guard wanted.count > 1 else { return nil }
        let tail = Array(wanted.dropFirst())
        let partial = titled.filter { $0.1.count > 1 && Array($0.1.dropFirst()) == tail }
        return partial.count == 1 ? partial[0].0 : nil
    }

    /// Title split at VS Code's separator, without the dirty marker and the app name, which
    /// AX titles may carry and `--status` titles do not.
    static func normalizedSegments(_ title: String) -> [String] {
        var t = title.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\u{25CF} ") { t.removeFirst(2) }
        var segments = t.components(separatedBy: " \u{2014} ").map { $0.trimmingCharacters(in: .whitespaces) }
        if let last = segments.last, segments.count > 1,
           last.hasPrefix("Visual Studio Code") || last == "VSCodium" {
            segments.removeLast()
        }
        return segments.filter { !$0.isEmpty }
    }
}

/// VS Code runs a renderer, an extension host and a file watcher per window; language servers
/// and agents hang off the extension host.
enum VSCodeWindows {

    static let bundleIds: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]

    static func mapping(mainPid: pid_t, executable: URL, bundle: URL, timeout: TimeInterval = 15) async -> WindowMapping {
        let cli = bundle.appendingPathComponent("Contents/Resources/app/out/cli.js")
        let output = await runStatus(executable: executable, cli: cli, timeout: timeout)
        return mapping(mainPid: mainPid, statusOutput: output)
    }

    /// Builds the mapping from `code --status` output, or from env/fd heuristics when the
    /// output is nil. The kernel's view (parent pid, file watcher env) wins over `--status`.
    static func mapping(mainPid: pid_t, statusOutput: String?) -> WindowMapping {
        var watcherRenderer: [pid_t: pid_t] = [:]
        var extensionHosts: [pid_t] = []
        for pid in ProcessControl.processTree(root: mainPid) where AppProcesses.parentPid(of: pid) == mainPid {
            guard let env = AppProcesses.commandLine(of: pid)?.env else { continue }
            switch env["VSCODE_CRASH_REPORTER_PROCESS_TYPE"] {
            case "fileWatcher": watcherRenderer[pid] = env["VSCODE_PARENT_PID"].flatMap { pid_t($0) }
            case "extensionHost": extensionHosts.append(pid)
            default: break
            }
        }

        var windows: [Int: (title: String?, renderer: pid_t?, extensionHost: pid_t?, watcher: pid_t?)] = [:]
        let source: WindowMapping.Source
        if let statusOutput {
            source = .statusCommand
            let parsed = parseStatus(statusOutput)
            for entry in parsed.entries {
                var w = windows[entry.id] ?? (nil, nil, nil, nil)
                switch entry.kind {
                case "window": w.renderer = entry.pid; w.title = entry.title
                case "extension-host": w.extensionHost = entry.pid
                default: w.watcher = entry.pid
                }
                windows[entry.id] = w
            }
            // --status was seen omitting a window's renderer line, and with it the title. The
            // workspace summary still lists every window title, without ids: one unclaimed
            // title for one untitled window is unambiguous.
            let claimed = Set(windows.values.compactMap(\.title))
            let unclaimed = parsed.workspaceTitles.filter { !claimed.contains($0) }
            let untitled = windows.filter { $0.value.title == nil }.map(\.key)
            if unclaimed.count == 1, untitled.count == 1 { windows[untitled[0]]?.title = unclaimed[0] }
        } else {
            source = .processScan
            var freeWatchers = watcherRenderer.keys.sorted()
            for host in extensionHosts.sorted() {
                guard let id = extensionHostWindowId(host) else { continue }
                // ponytail: VS Code spawns a window's file watcher right after its extension
                // host, so the next watcher pid is the pair (seen gaps 1-3). Breaks if pids
                // wrap or windows open concurrently; the --status path does not rely on it.
                let watcher = freeWatchers.first { $0 > host && $0 - host <= 16 }
                freeWatchers.removeAll { $0 == watcher }
                windows[id] = (nil, nil, host, watcher)
            }
        }

        let tree = ProcessControl.processTree(root: mainPid)
        let children = Set(tree.filter { AppProcesses.parentPid(of: $0) == mainPid })
        var groups: [WindowGroup] = []
        for (id, w) in windows {
            var anchors: [String: pid_t] = [:]
            anchors["renderer"] = w.watcher.flatMap { watcherRenderer[$0] } ?? w.renderer
            anchors["extension host"] = w.extensionHost
            anchors["file watcher"] = w.watcher
            // Only direct children of this VS Code count: guards against a stale --status pid
            // reused by an unrelated process.
            anchors = anchors.filter { children.contains($0.value) }
            guard !anchors.isEmpty else { continue }
            var pids = Set<pid_t>()
            for pid in anchors.values { pids.formUnion(ProcessControl.processTree(root: pid)) }
            groups.append(WindowGroup(id: id, title: w.title, anchors: anchors, pids: pids))
        }
        groups.sort { $0.id < $1.id }
        let grouped = groups.reduce(into: Set<pid_t>()) { $0.formUnion($1.pids) }
        return WindowMapping(groups: groups, shared: tree.filter { !grouped.contains($0) }, source: source)
    }

    struct StatusEntry: Equatable {
        let kind: String
        let id: Int
        let pid: pid_t
        let title: String?
    }

    private static let entryPattern = try! Regex(#"^(window|extension-host|file-watcher) \[(\d+)\](?: \((.*)\))?$"#)

    /// Process lines are "CPU\tMem\tPID\tname"; only lines with a window id are kept, so
    /// renderers printed as a bare "window" (no window behind them) fall into `shared`.
    static func parseStatus(_ output: String) -> (entries: [StatusEntry], workspaceTitles: [String]) {
        var entries: [StatusEntry] = []
        var titles: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("|  Window ("), line.hasSuffix(")") {
                titles.append(String(line.dropFirst("|  Window (".count).dropLast()))
                continue
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4, let pid = pid_t(fields[2].trimmingCharacters(in: .whitespaces)) else { continue }
            let name = fields[3].trimmingCharacters(in: .whitespaces)
            guard let m = name.wholeMatch(of: entryPattern),
                  let kind = m[1].substring, let id = m[2].substring.flatMap({ Int($0) }) else { continue }
            entries.append(StatusEntry(kind: String(kind), id: id, pid: pid, title: m[3].substring.map(String.init)))
        }
        return (entries, titles)
    }

    /// Runs VS Code's CLI (`code --status`) off the main thread. The `bin/code` wrapper is
    /// bypassed: it is a bash script that does not exec, so a timeout would kill bash and
    /// leave Electron holding the pipe.
    static func runStatus(executable: URL, cli: URL, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = [cli.path, "--status"]
                var env = ProcessInfo.processInfo.environment
                env["ELECTRON_RUN_AS_NODE"] = "1"
                // Inside a VS Code terminal this would route the CLI to that terminal's window.
                env["VSCODE_IPC_HOOK_CLI"] = nil
                env["NODE_OPTIONS"] = nil
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                let ok = process.terminationReason == .exit && process.terminationStatus == 0
                let text = String(decoding: data, as: UTF8.self)
                continuation.resume(returning: ok && text.contains("extension-host [") ? text : nil)
            }
        }
    }

    /// Window number from the extension host's open log file `.../windowN/exthost/...`.
    static func extensionHostWindowId(_ pid: pid_t) -> Int? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return nil }
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard let r = path.range(of: #"/window(\d+)/exthost/"#, options: .regularExpression) else { continue }
            return Int(path[r].dropFirst("/window".count).prefix { $0.isNumber })
        }
        return nil
    }
}
