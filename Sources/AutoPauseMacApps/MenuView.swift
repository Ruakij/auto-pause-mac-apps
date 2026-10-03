import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppListModel
    /// Lets the user re-open the first-run walkthrough from the menu.
    var showOnboarding: () -> Void = {}
    @State private var showSystemDetail = false
    @State private var showReclaim = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var showSettings = false

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
                .frame(height: listHeight(sections: [suspended.count, running.count]))
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
            .disabled(model.pausedCount == 0)
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .help("Settings")
            .popover(isPresented: $showSettings, arrowEdge: .top) {
                settingsPanel
            }

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

            Divider()

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

    /// Tall enough for every row, capped at the screen. Computed from row counts with fixed
    /// metrics rather than measured, so the window keeps its size across the periodic refresh
    /// unless the number of rows changes.
    private func listHeight(sections rowCounts: [Int]) -> CGFloat {
        let rowHeight: CGFloat = 39    // two text lines + vertical padding
        let headerHeight: CGFloat = 19 // section title + its padding
        let spacing: CGFloat = 2
        let rows = rowCounts.reduce(0, +)
        let headers = rowCounts.filter { $0 > 0 }.count
        let contentHeight = CGFloat(rows) * rowHeight
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

    var body: some View {
        HStack(spacing: 8) {
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
                    if PauseFlags.hasSeenDeepSleepWarning {
                        model.deepSleep(entry)
                    } else {
                        showSleepWarning = true
                    }
                } label: {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.indigo)
                }
                .buttonStyle(.plain)
                .help("Deep Sleep \(entry.name) — quit it and free all its memory (recoverable)")
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
            } else {
                Button {
                    entry.state == .running ? model.pause(entry) : model.resume(entry)
                } label: {
                    Image(systemName: entry.state == .running ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(entry.state == .running ? .blue : .green)
                }
                .buttonStyle(.plain)
                .help(actionHelp)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.06) : rowTint)
        )
        .onHover { hovering = $0 }
    }

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
            if entry.reclaimedBytes > 0 {
                Text("freed \(MenuView.fmt(entry.reclaimedBytes))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        .foregroundStyle(.secondary)
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
