import Foundation
import Darwin
import ApplicationServices

/// The processes of one VS Code window: its renderer, its file watcher and its extension host,
/// frozen together with their descendants.
struct VSCodeWindow: Equatable {
    /// VS Code's window number (`logs/<session>/windowN`), stable while the window is open.
    let id: Int
    /// Workspace folder name, "Window N" when none was found.
    let label: String
    /// Workspace folder path, when known.
    let path: String?
    let renderer: pid_t
    let fileWatcher: pid_t
    let extensionHost: pid_t

    var anchors: [pid_t] { [renderer, extensionHost, fileWatcher] }
}

/// Maps VS Code's per-window processes from kernel data of the running processes only (env,
/// open files, start times, working directories). Nothing is launched: `code --status` starts a
/// new Code instance per call. A process that does not map stays a plain node of the tree.
enum VSCodeWindows {

    /// VS Code and builds of the same source; forks with their own changes (Cursor, Windsurf)
    /// are not assumed to keep the mapping.
    static let bundleIDs: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]

    private enum Role {
        case fileWatcher(renderer: pid_t)
        case extensionHost
        case renderer
        case other
    }

    /// What one process's command line and environment say, read once per pid and start time.
    private struct Process {
        let start: Date?
        let role: Role
        /// For an extension host: window number and `workspace.json` folder from its open files,
        /// kept once the number is found (a host opens its log files shortly after it starts).
        var files: (window: Int, folder: String?)?
    }

    @MainActor private static var processes: [pid_t: Process] = [:]

    @MainActor private static func process(_ pid: pid_t) -> Process {
        let start = ProcessControl.startTime(of: pid)
        if let cached = processes[pid], cached.start == start { return cached }
        let keys: Set<String> = ["VSCODE_CRASH_REPORTER_PROCESS_TYPE", "VSCODE_PARENT_PID"]
        let line = AppProcesses.commandLine(of: pid, envKeys: keys)
        let role: Role
        switch line?.env["VSCODE_CRASH_REPORTER_PROCESS_TYPE"] {
        // VS Code sets it to the renderer of the window the watcher serves.
        case "fileWatcher": role = line?.env["VSCODE_PARENT_PID"].flatMap { pid_t($0) }.map { .fileWatcher(renderer: $0) } ?? .other
        case "extensionHost": role = .extensionHost
        default: role = line.flatMap { AppProcesses.flag("type", in: $0.args) } == "renderer" ? .renderer : .other
        }
        let process = Process(start: start, role: role)
        processes[pid] = process
        return process
    }

    @MainActor private static func files(ofHost pid: pid_t) -> (window: Int, folder: String?)? {
        if let files = processes[pid]?.files { return files }
        let paths = openPaths(of: pid)
        guard let id = paths.lazy.compactMap(windowNumber).first else { return nil }
        let files = (id, paths.lazy.compactMap(workspaceFolder).first)
        processes[pid]?.files = files
        return files
    }

    @MainActor static func windows(main: pid_t) -> [VSCodeWindow] {
        let children = ProcessControl.children(of: main)
        let childSet = Set(children)
        var watchers: [(pid: pid_t, renderer: pid_t)] = []
        var hosts: [pid_t] = []
        var renderers: Set<pid_t> = []
        for pid in children {
            switch process(pid).role {
            case .fileWatcher(let renderer): watchers.append((pid, renderer))
            case .extensionHost: hosts.append(pid)
            case .renderer: renderers.insert(pid)
            case .other: break
            }
        }
        processes = processes.filter { childSet.contains($0.key) || ProcessControl.isAlive($0.key) }
        watchers = watchers.filter { renderers.contains($0.renderer) }

        // ponytail: start-time pairing. VS Code starts a window's extension host and file
        // watcher together (measured: same second, pids 1-7 apart, either one first), and no
        // kernel data or log links them: renderer.log names only the extension host's pid.
        // Two windows opening within the tolerance leave both unmapped rather than guessed.
        let tolerance: TimeInterval = 2
        func near(_ a: pid_t, _ b: pid_t) -> Bool {
            guard let x = processes[a]?.start, let y = processes[b]?.start else { return false }
            return abs(x.timeIntervalSince(y)) <= tolerance
        }

        var result: [VSCodeWindow] = []
        for host in hosts {
            let candidates = watchers.filter { near(host, $0.pid) }
            guard candidates.count == 1, let watcher = candidates.first,
                  hosts.filter({ near($0, watcher.pid) }).count == 1,
                  let files = files(ofHost: host) else { continue }
            let id = files.window
            let folder = files.folder ?? commonWorkingDirectory(below: host)
            result.append(VSCodeWindow(
                id: id, label: folder.map { ($0 as NSString).lastPathComponent } ?? "Window \(id)", path: folder,
                renderer: watcher.renderer, fileWatcher: watcher.pid, extensionHost: host))
        }
        // One window per renderer and per number; anything doubled is left unmapped.
        return result.filter { w in
            result.filter { $0.renderer == w.renderer || $0.id == w.id }.count == 1
        }.sorted { $0.id < $1.id }
    }

    /// N from `.../windowN/exthost/...`, which only the extension host of window N writes.
    static func windowNumber(_ path: String) -> Int? {
        guard let r = path.range(of: #"/window\d+/exthost/"#, options: .regularExpression) else { return nil }
        return Int(path[r].dropFirst("/window".count).prefix { $0.isNumber })
    }

    /// The folder (or `.code-workspace` file) named by `workspace.json` of the
    /// `workspaceStorage/<hash>/` directory a path lies in.
    static func workspaceFolder(_ path: String) -> String? {
        guard let r = path.range(of: #"/workspaceStorage/[0-9a-f]+/"#, options: .regularExpression),
              let data = FileManager.default.contents(atPath: path[..<r.upperBound] + "workspace.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let folder = json["folder"] as? String { return URL(string: folder)?.path }
        if let workspace = json["workspace"] as? String { return URL(string: workspace)?.deletingPathExtension().path }
        return nil
    }

    /// The working directory most children of the extension host share (language servers and
    /// agents run in the workspace folder); "/" does not count.
    static func commonWorkingDirectory(below pid: pid_t) -> String? {
        let dirs = ProcessControl.children(of: pid).compactMap(workingDirectory).filter { $0 != "/" }
        let counts = Dictionary(dirs.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// Paths of the files a process holds open.
    static func openPaths(of pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        return fds.prefix(Int(filled) / stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            return withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
    }

    /// AX window -> window number, kept from the last time that window matched one-to-one. A
    /// window keeps both for its lifetime, so the entry stays right while the number is mapped.
    @MainActor private static var focusCache: [AXUIElement: Int] = [:]

    /// The window that has focus in VS Code; nil when it cannot be told. The focused AX window
    /// must have exactly one candidate (`candidates`), and no other AX window may have that one
    /// too. Otherwise the last one-to-one match of the same AX window counts. AX lists only the
    /// windows of the current Space, so a window on another Space cannot veto a match.
    @MainActor static func focusedWindow(app: pid_t, in windows: [VSCodeWindow]) -> VSCodeWindow? {
        let ids = Set(windows.map(\.id))
        focusCache = focusCache.filter { ids.contains($0.value) }
        guard let texts = Accessibility.windowTexts(pid: app) else { return nil }
        let found = candidates(texts.focused, in: windows)
        if found.count == 1, let window = found.first,
           !texts.others.contains(where: { candidates($0, in: windows).contains(window) }) {
            focusCache[texts.focused.element] = window.id
            return window
        }
        return focusCache[texts.focused.element].flatMap { id in windows.first { $0.id == id } }
    }

    /// The windows an AX window may be. Its title must name the label as a word of its own (not
    /// preceded or followed by a word character, "." or "-"), so "svs" does not match
    /// "app-svs-apigateway". The active editor's file is no hint: a window can have files of any
    /// folder open, including another window's, so an editor named like another window's folder
    /// leaves two candidates.
    static func candidates(_ text: Accessibility.WindowText, in windows: [VSCodeWindow]) -> [VSCodeWindow] {
        guard let title = text.title else { return [] }
        return windows.filter { w in
            let pattern = #"(?<![\w.-])"# + NSRegularExpression.escapedPattern(for: w.label) + #"(?![\w.-])"#
            return title.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
