import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppListModel
    /// Lets the user re-open the first-run walkthrough from the menu.
    var showOnboarding: () -> Void = {}
    @State private var showSystemDetail = false
    @State private var showReclaim = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var showSettings = false
    @State private var settingsPage: SettingsPage?

    private enum SettingsPage { case busyConditions, neverFreeze }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = model.notice {
                noticeBar(notice)
                Divider()
            }
            if model.entries.isEmpty {
                Text("No apps to show")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 80)
            } else {
                let suspended = model.entries.filter { $0.state != .running }
                let running = model.entries.filter { $0.state == .running }
                ScrollView {
                    VStack(spacing: 2) {
                        section("SUSPENDED", suspended)
                        section("APPS", running)
                    }
                    .padding(6)
                }
                // An explicit height, not maxHeight: a ScrollView has no intrinsic size, so
                // the MenuBarExtra window would collapse it.
                .frame(height: listHeight(sections: [suspended.count, running.count],
                                          stateLines: running.filter(\.showsState).count)
                       + model.entries.compactMap { $0.pid.flatMap { model.details[$0] }?.height }.reduce(0, +))
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { model.startRefreshing() }
        .onDisappear { model.stopRefreshing() }
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill").font(.caption2).foregroundStyle(.orange)
            Text(text).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                model.notice = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Pause").font(.headline)
                Spacer()
                if model.pausedCount > 0 {
                    Label("\(model.pausedCount) suspended", systemImage: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            Button {
                showSystemDetail = true
            } label: {
                HStack {
                    RingGaugeView(fraction: model.systemStats.usedFraction, lineWidth: 3, showLabel: false)
                        .frame(width: 22, height: 22)
                    Text("Memory: \(Self.fmt(model.usedMemory)) of \(Self.fmt(model.totalMemory)) used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSystemDetail, arrowEdge: .bottom) {
                SystemDetailView(model: model, stats: model.systemStats)
            }

            UsageAreaChart(history: model.systemHistory, totalBytes: model.totalMemory, accent: pressureAccent)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var pressureAccent: Color {
        switch model.systemStats.usedFraction {
        case ..<0.6: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [AppEntry]) -> some View {
        if !items.isEmpty {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)

            ForEach(items) { entry in
                AppRow(entry: entry, model: model)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                showReclaim = true
            } label: {
                Label("Free Up Memory", systemImage: "cpu")
            }
            .popover(isPresented: $showReclaim, arrowEdge: .top) {
                ReclaimView(model: model) { showReclaim = false }
            }
            Spacer()
            Button {
                model.resumeAll()
            } label: {
                Label("Resume All", systemImage: "play.circle")
            }
            .disabled(model.pausedCount + model.frozenWindowCount == 0)
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .help("Settings")
            .popover(isPresented: $showSettings, arrowEdge: .top) {
                switch settingsPage {
                case .busyConditions: BusySettingsView(model: model) { settingsPage = nil }
                case .neverFreeze: NeverFreezeSettingsView(model: model) { settingsPage = nil }
                case nil: settingsPanel
                }
            }
            .onChange(of: showSettings) { _, _ in settingsPage = nil }

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Pause (resumes frozen apps)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.system(size: 13, weight: .semibold))

            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Start at login").font(.system(size: 12, weight: .medium))
                    Text("Keep it running so it's there when you need it")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: launchAtLogin) { _, wants in
                if case .failure(let error) = LaunchAtLogin.set(wants) {
                    model.notice = "Couldn't change the login item: \(error.localizedDescription)"
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            }

            if LaunchAtLogin.requiresApproval {
                Button {
                    LaunchAtLogin.openLoginItemsSettings()
                } label: {
                    Label("Approve in System Settings", systemImage: "arrow.up.forward.app")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }

            accessibilityRow

            Divider()

            pageLink("Busy conditions", systemImage: "hourglass", page: .busyConditions)
            pageLink("Never freeze", systemImage: "lock", page: .neverFreeze)

            Button {
                showSettings = false
                showOnboarding()
            } label: {
                Label("Show the walkthrough again", systemImage: "sparkles")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Link(destination: URL(string: "https://github.com/fazalrshah/auto-pause-mac-apps")!) {
                Label("Source & docs on GitHub", systemImage: "link")
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 250)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func pageLink(_ title: String, systemImage: String, page: SettingsPage) -> some View {
        Button {
            settingsPage = page
        } label: {
            HStack {
                Label(title, systemImage: systemImage).font(.caption)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Read on every render: trust can be granted while the app runs.
    @ViewBuilder
    private var accessibilityRow: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("Accessibility").font(.system(size: 12, weight: .medium))
                Spacer()
                if Accessibility.isTrusted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
            Text("Pauses single VS Code windows and resumes one when it is clicked")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !Accessibility.isTrusted {
                Button {
                    Accessibility.openSettings()
                } label: {
                    Label("Allow in System Settings", systemImage: "arrow.up.forward.app")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
        }
    }

    /// Tall enough for every row, capped at the screen. Computed from row counts with fixed
    /// metrics rather than measured, so the window keeps its size across the periodic refresh
    /// unless the number of rows changes.
    private func listHeight(sections rowCounts: [Int], stateLines: Int) -> CGFloat {
        let rowHeight: CGFloat = 39    // two text lines + vertical padding
        let stateLineHeight: CGFloat = 13
        let headerHeight: CGFloat = 19 // section title + its padding
        let spacing: CGFloat = 2
        let rows = rowCounts.reduce(0, +)
        let headers = rowCounts.filter { $0 > 0 }.count
        let contentHeight = CGFloat(rows) * rowHeight + CGFloat(stateLines) * stateLineHeight
            + CGFloat(headers) * headerHeight
            + CGFloat(max(0, rows + headers - 1)) * spacing
            + 12 // VStack padding
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let chromeHeight: CGFloat = 210 // header + usage graph + divider + footer + padding
        return min(contentHeight, max(200, screenHeight - chromeHeight))
    }

    static func fmt(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        return f.string(fromByteCount: Int64(bytes))
    }
}

private struct AppRow: View {
    let entry: AppEntry
    @ObservedObject var model: AppListModel
    @State private var hovering = false
    @State private var showDetail = false
    @State private var showSleepWarning = false
    /// After a click on a busy app, the matching button turns into Force and the state line
    /// shows the findings until the pointer leaves the row or the time runs out.
    @StateObject private var gate = BusyGate()

    var body: some View {
        VStack(spacing: 0) {
            row
            if let pid = entry.pid, let detail = model.details[pid] {
                ProcessListView(entry: entry, detail: detail, model: model)
                    .padding(.leading, 30)
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.06) : rowTint)
        )
    }

    private var row: some View {
        HStack(spacing: 8) {
            if let pid = entry.pid {
                Button { model.toggleExpanded(pid) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.expanded.contains(pid) ? 90 : 0))
                        .frame(width: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Processes")
            } else {
                Color.clear.frame(width: 10)
            }
            if let icon = entry.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .saturation(entry.state == .running ? 1 : 0)
                    .opacity(entry.state == .running ? 1 : 0.6)
            } else {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    badge
                }
                memoryLine
                if entry.showsState || gate.text != nil { stateLine }
            }

            if entry.history.count > 1 {
                SparklineView(history: entry.history, color: entry.state == .running ? .blue : .gray)
                    .frame(width: 44, height: 20)
            }

            Spacer(minLength: 4)

            if entry.state != .sleeping {
                Button { showDetail = true } label: {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Memory history & settings")
                .popover(isPresented: $showDetail, arrowEdge: .trailing) {
                    AppDetailView(entry: entry, model: model)
                }
            }

            // Deep Sleep — quits the app, freeing everything including swap.
            if entry.canDeepSleep {
                Button {
                    gate.check(.deepSleep, entry: entry, model: model) {
                        if PauseFlags.hasSeenDeepSleepWarning {
                            model.deepSleep(entry)
                        } else {
                            showSleepWarning = true
                        }
                    }
                } label: {
                    if gate.armed == .deepSleep {
                        forceLabel("moon.zzz.fill")
                    } else {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.indigo)
                    }
                }
                .buttonStyle(.plain)
                .help(gate.armed == .deepSleep ? forceHelp : "Deep Sleep \(entry.name) — quit it and free all its memory (recoverable)")
                .popover(isPresented: $showSleepWarning, arrowEdge: .trailing) {
                    DeepSleepWarningView(
                        entry: entry,
                        status: DeepSleepController.canRestoreState(bundleID: entry.bundleID),
                        onCancel: { showSleepWarning = false },
                        onProceed: {
                            showSleepWarning = false
                            model.deepSleep(entry)
                        })
                }
            }

            // Pause / Resume / Wake. Sleeping rows get an explicit labelled button — an
            // icon alone left it unclear that a quit app could be brought straight back.
            if entry.state == .sleeping {
                Button {
                    model.resume(entry)
                } label: {
                    Label("Wake", systemImage: "play.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
                .help(actionHelp)
            } else if entry.state == .running && entry.neverFreeze {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .help("On the Never freeze list")
            } else {
                Button {
                    if entry.state == .running {
                        gate.check(.pause, entry: entry, model: model) { model.pause(entry) }
                    } else {
                        model.resume(entry)
                    }
                } label: {
                    if gate.armed == .pause {
                        forceLabel("pause.circle.fill")
                    } else {
                        Image(systemName: entry.state == .running ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(entry.state == .running ? .blue : .green)
                    }
                }
                .buttonStyle(.plain)
                .help(gate.armed == .pause ? forceHelp : actionHelp)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .onHover { inside in
            hovering = inside
            if !inside { gate.clear() }
        }
    }

    private func forceLabel(_ systemImage: String) -> some View {
        Label("Force", systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange, in: Capsule())
            .foregroundStyle(.white)
    }

    private var forceHelp: String { "\(gate.text ?? "Busy"). Click again to proceed anyway." }

    @ViewBuilder
    private var badge: some View {
        switch entry.state {
        case .running:
            if AppSettingsStore.shared.settings(for: entry.bundleID).autoPauseEnabled {
                Image(systemName: "timer").font(.system(size: 8)).foregroundStyle(.secondary)
            }
        case .paused:
            tag("FROZEN", .blue)
        case .sleeping:
            tag("SLEEPING", .indigo)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    /// Primary number is resident RAM — the memory actually held right now, which drops
    /// when an app is frozen. Footprint is shown dimmer because it counts compressed and
    /// swapped pages and so barely moves.
    private var memoryLine: some View {
        HStack(spacing: 5) {
            if entry.state == .sleeping {
                Text("quit — 0 bytes held").font(.system(size: 10))
            } else {
                Text(MenuView.fmt(entry.resident)).font(.system(size: 10)).monospacedDigit()
                Text(MenuView.fmt(entry.footprint))
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(.tertiary)
            }
            if entry.frozenWindows > 0 {
                Text(entry.windowCount.map { "\(entry.frozenWindows) of \($0) windows paused" }
                     ?? "\(entry.frozenWindows) window\(entry.frozenWindows == 1 ? "" : "s") paused")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.blue)
            }
            if entry.reclaimedBytes > 0 {
                Text("freed \(MenuView.fmt(entry.reclaimedBytes))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        .foregroundStyle(.secondary)
    }

    /// Busy or idle as of the last live pass, or the Force step's findings.
    @ViewBuilder
    private var stateLine: some View {
        let state = entry.pid.flatMap { model.appStates[$0] }
        Group {
            if let text = gate.text {
                Text(text).foregroundStyle(.orange)
            } else if let state {
                Text(state.text()).foregroundStyle(state.busy.isEmpty ? .secondary : Color.orange)
            } else {
                Text("Checking...").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 9))
        .lineLimit(1).truncationMode(.tail)
    }

    private var rowTint: Color {
        switch entry.state {
        case .running: return .clear
        case .paused: return Color.blue.opacity(0.06)
        case .sleeping: return Color.indigo.opacity(0.09)
        }
    }

    private var actionHelp: String {
        switch entry.state {
        case .running: return "Pause \(entry.name) — freeze it, keep it in memory"
        case .paused: return "Resume \(entry.name)"
        case .sleeping: return "Wake \(entry.name) — relaunch and restore its windows"
        }
    }
}

/// The busy step before a manual Pause or Deep Sleep, shared by the row and the detail popover.
@MainActor
final class BusyGate: ObservableObject {
    enum Action { case pause, deepSleep }

    /// The button armed as Force, and the findings text shown meanwhile.
    @Published private(set) var armed: Action?
    @Published private(set) var text: String?
    /// A check or an async `proceed` is running.
    @Published private(set) var checking = false
    /// Bumped by `clear()`, so a check that finishes after the pointer left or after a reset
    /// is ignored.
    private var generation = 0
    private var reset: Task<Void, Never>?

    /// Follows the state on screen: a row shown idle proceeds at once, one shown busy arms
    /// Force with that text. Without a shown state (panel just opened, never-freeze app) the
    /// findings are checked first. The same button just armed as Force proceeds. Clicks while a
    /// check runs are ignored.
    func check(_ action: Action, entry: AppEntry, model: AppListModel, proceed: @escaping () -> Void) {
        check(action, shown: entry.pid.flatMap { model.appStates[$0] },
              findings: { await model.busyFindings(for: entry) }, proceed: proceed)
    }

    func check(_ action: Action, shown: LiveState?, findings check: @escaping () async -> [BusyFinding],
               proceed: @escaping () async -> Void) {
        guard !checking else { return }
        let forced = armed == action
        clear()
        if !forced, let shown, !shown.busy.isEmpty { return arm(action, text: shown.busyText) }
        checking = true
        let started = generation
        Task { @MainActor in
            defer { checking = false }
            if forced || shown != nil { return await proceed() }
            let findings = await check()
            guard started == generation else { return }
            guard !findings.isEmpty else { return await proceed() }
            arm(action, text: "Busy: " + findings.summary)
        }
    }

    private func arm(_ action: Action, text: String) {
        self.text = text
        armed = action
        reset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self.clear() }
        }
    }

    func clear() {
        generation += 1
        reset?.cancel()
        reset = nil
        armed = nil
        text = nil
    }
}

extension AppEntry {
    /// Rows that can be paused show busy or idle under the memory line.
    var showsState: Bool { state == .running && !neverFreeze }
}

extension AppDetail {
    static let processLineHeight: CGFloat = 15
    static let windowHeaderHeight: CGFloat = 30

    /// Height of the expanded part of a row, from fixed line metrics like `listHeight`.
    var height: CGFloat {
        let lines: CGFloat
        if let windows {
            lines = CGFloat(windows.count + 1) * Self.windowHeaderHeight
                + CGFloat(windows.reduce(0) { $0 + $1.processes.count } + shared.count) * Self.processLineHeight
        } else {
            lines = CGFloat(processes.count) * Self.processLineHeight
        }
        return lines + 6
    }
}

/// The expanded part of an app row: windows with their processes and the shared rest, or the
/// plain process tree. Only windows can be paused; processes are view-only.
private struct ProcessListView: View {
    let entry: AppEntry
    let detail: AppDetail
    @ObservedObject var model: AppListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let windows = detail.windows {
                ForEach(windows) { window in
                    WindowSection(entry: entry, window: window, model: model)
                    ForEach(window.processes) { ProcessLine(process: $0) }
                }
                HStack(spacing: 6) {
                    Text("Shared").font(.system(size: 10, weight: .semibold))
                    Spacer()
                    totals(resident: detail.shared.reduce(0) { $0 + $1.resident },
                           cpu: detail.shared.compactMap(\.cpuPercent).reduce(0, +))
                }
                .help("Serves every window, so it is never paused per window")
                .frame(height: AppDetail.windowHeaderHeight)
                ForEach(detail.shared) { ProcessLine(process: $0) }
            } else {
                ForEach(detail.processes) { ProcessLine(process: $0) }
            }
        }
    }
}

private func totals(resident: UInt64, cpu: Double?) -> some View {
    HStack(spacing: 6) {
        Text(cpu.map { String(format: "%.1f%%", $0) } ?? "-").frame(width: 44, alignment: .trailing)
        Text(MenuView.fmt(resident)).frame(width: 56, alignment: .trailing)
    }
    .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
}

private struct ProcessLine: View {
    let process: ProcessStat

    var body: some View {
        HStack(spacing: 4) {
            Text(process.name).lineLimit(1).truncationMode(.middle)
                .padding(.leading, CGFloat(min(process.depth, 6)) * 8)
            if let role = process.role, role != process.name {
                Text(role).lineLimit(1).foregroundStyle(.tertiary)
            }
            if process.stopped {
                Image(systemName: "pause.fill").foregroundStyle(.blue).help("Frozen")
            }
            Spacer(minLength: 4)
            totals(resident: process.resident, cpu: process.cpuPercent)
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .frame(height: AppDetail.processLineHeight)
    }
}

private struct WindowSection: View {
    let entry: AppEntry
    let window: WindowDetail
    @ObservedObject var model: AppListModel
    @StateObject private var gate = BusyGate()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "macwindow").font(.system(size: 9)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(window.title).font(.system(size: 10, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                stateLine
            }
            Spacer(minLength: 4)
            totals(resident: window.resident, cpu: window.cpuPercent)
            button
        }
        .frame(height: AppDetail.windowHeaderHeight)
        .onHover { if !$0 { gate.clear() } }
    }

    private var state: LiveState? {
        entry.pid.flatMap { model.windowStates[WindowKey(pid: $0, window: window.id)] }
    }

    @ViewBuilder
    private var stateLine: some View {
        Group {
            if let text = gate.text {
                Text(text).foregroundStyle(.orange)
            } else if gate.checking {
                Text("Checking...").foregroundStyle(.secondary)
            } else if window.frozen || entry.neverFreeze {
                EmptyView()
            } else if let state {
                Text(state.text()).foregroundStyle(state.busy.isEmpty ? .secondary : Color.orange)
            } else {
                Text("Checking...").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 9))
        .lineLimit(1).truncationMode(.tail)
    }

    @ViewBuilder
    private var button: some View {
        if window.frozen {
            Button { model.resumeWindow(entry, window: window.id) } label: {
                Image(systemName: "play.circle.fill").font(.system(size: 15)).foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Resume this window")
        } else if !entry.neverFreeze {
            let trusted = Accessibility.isTrusted
            let pids = window.processes.map(\.pid)
            Button {
                gate.check(.pause, shown: state, findings: { await model.busyFindings(pids: pids) }) {
                    await model.pauseWindow(entry, window: window.id)
                }
            } label: {
                if gate.armed == .pause {
                    Text("Force").font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange, in: Capsule()).foregroundStyle(.white)
                } else {
                    Image(systemName: "pause.circle.fill").font(.system(size: 15))
                        .foregroundStyle(trusted ? .blue : .gray)
                }
            }
            .buttonStyle(.plain)
            .disabled(!trusted)
            .help(!trusted
                  ? "Needs Accessibility (Settings): without it a paused window would only resume from here, not when clicked"
                  : gate.armed == .pause ? "\(gate.text ?? "Busy"). Click again to proceed anyway." : "Pause this window")
        }
    }
}
