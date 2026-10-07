import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppListModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showSystemDetail = false
    @State private var showReclaim = false
    /// Row order frozen while the pointer is in the list, so a row that changes state does not
    /// move away under the next click; nil re-sorts.
    @State private var pinned: (top: [String], apps: [String])?

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
                let (top, apps) = sections
                ScrollView {
                    VStack(spacing: 2) {
                        section(Self.stoppedTitle(top), top)
                        section("APPS", apps)
                    }
                    .padding(6)
                }
                // An explicit height, not maxHeight: a ScrollView has no intrinsic size, so
                // the MenuBarExtra window would collapse it.
                .frame(height: listHeight(sections: [top.count, apps.count],
                                          stateLines: model.entries.filter(\.showsState).count))
                .onHover { inside in
                    pinned = inside ? (top.map(Self.pinKey), apps.map(Self.pinKey)) : nil
                }
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { model.startRefreshing() }
        // A panel closed under the pointer gets no hover exit.
        .onDisappear { pinned = nil; model.stopRefreshing() }
    }

    /// Paused and deep-slept apps on top, running ones below, each in model order; while
    /// pinned, the pinned order with new rows appended.
    private var sections: (top: [AppEntry], apps: [AppEntry]) {
        let entries = model.entries
        guard let pinned else {
            return (entries.filter { $0.state != .running }, entries.filter { $0.state == .running })
        }
        let byId = Dictionary(entries.map { (Self.pinKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(pinned.top + pinned.apps)
        let new = entries.filter { !known.contains(Self.pinKey($0)) }
        return (pinned.top.compactMap { byId[$0] } + new.filter { $0.state != .running },
                pinned.apps.compactMap { byId[$0] } + new.filter { $0.state == .running })
    }

    /// The entry id switches between pid and bundle ID on Deep Sleep and Wake; pinning by
    /// bundle ID keeps that row in place.
    private static func pinKey(_ entry: AppEntry) -> String { entry.bundleID ?? entry.id }

    /// "2 paused, 1 asleep", the parts that are not zero.
    private static func stoppedCounts(_ entries: [AppEntry]) -> [String] {
        let paused = entries.filter { $0.state == .paused }.count
        let asleep = entries.filter { $0.state == .sleeping }.count
        return [paused > 0 ? "\(paused) paused" : nil, asleep > 0 ? "\(asleep) asleep" : nil].compactMap { $0 }
    }

    private static func stoppedTitle(_ entries: [AppEntry]) -> String {
        let hasPaused = entries.contains { $0.state == .paused }
        let hasAsleep = entries.contains { $0.state == .sleeping }
        return hasAsleep && !hasPaused ? "ASLEEP" : hasAsleep ? "PAUSED AND ASLEEP" : "PAUSED"
    }

    private func noticeBar(_ notice: Notice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: notice.isWarning ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.caption2).foregroundStyle(notice.isWarning ? .orange : .green)
            Text(notice.text).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                model.notice = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(notice.isWarning ? Color.orange.opacity(0.08) : Color.primary.opacity(0.04))
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Auto Pause").font(.headline)
                Spacer()
                if model.pausedCount > 0 {
                    Label(Self.stoppedCounts(model.entries).joined(separator: ", "), systemImage: "pause.circle.fill")
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
                Label("Free Up Memory", systemImage: "memorychip")
            }
            .popover(isPresented: $showReclaim, arrowEdge: .top) {
                ReclaimView(model: model) { showReclaim = false }
            }
            Spacer()
            let resumable = model.entries.filter { $0.state == .paused }.count
            Button {
                model.resumeAll()
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label(resumable > 0 ? "Resume All (\(resumable))" : "Resume All", systemImage: "play.circle")
                    Label("Resume All", systemImage: "play.circle")
                }
            }
            .disabled(resumable == 0)
            let sleeping = model.entries.filter { $0.state == .sleeping }.count
            if sleeping > 0 {
                Spacer()
                Button {
                    model.wakeAll()
                } label: {
                    Label("Wake all (\(sleeping))", systemImage: "sunrise")
                }
                .help("Relaunch every deep-slept app")
            }
            Spacer()
            Button {
                // Activating the app below keeps the panel key, so nothing else would close it.
                // dismiss is not reliable for MenuBarExtra windows; closing the key window (the
                // panel while it is open) covers that.
                dismiss()
                NSApp.keyWindow?.close()
                openSettings()
                // An LSUIElement app is not active, so its Settings window would open behind
                // the frontmost app.
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Auto Pause (resumes paused apps)")
            .accessibilityLabel("Quit Auto Pause")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        row.background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.06) : rowTint)
        )
    }

    private var waking: Bool { model.waking.contains(entry.id) }

    private var row: some View {
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
                if entry.showsState || gate.text != nil {
                    // A blank line until the first pass, so the row keeps its height.
                    liveStateLine(gateText: gate.text, state: entry.pid.flatMap { model.appStates[$0] })
                }
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
                .help("Details and auto-pause")
                .accessibilityLabel("Details and auto-pause for \(entry.name)")
                .popover(isPresented: $showDetail, arrowEdge: .trailing) {
                    AppDetailView(entry: entry, model: model)
                }
            }

            if entry.canDeepSleep {
                GatedButton(gate: gate, action: .deepSleep,
                            help: "Deep Sleep \(entry.name): quit it and free all its memory, relaunch on Wake",
                            voiceOver: "Deep Sleep \(entry.name)", perform: deepSleepTapped) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.indigo)
                }
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

            // Sleeping rows get an explicit labelled button: an icon alone left it unclear
            // that a quit app could be brought straight back.
            if entry.state == .sleeping {
                Button(action: mainAction) {
                    Label(waking ? "Waking..." : "Wake", systemImage: "play.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
                .disabled(waking)
                .help(actionHelp)
                .accessibilityLabel("Wake \(entry.name)")
            } else if entry.state == .running && entry.neverFreeze {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .help("On the Never freeze list")
                    .accessibilityLabel("\(entry.name) is on the Never freeze list")
            } else {
                GatedButton(gate: gate, action: .pause, help: actionHelp,
                            voiceOver: "\(entry.state == .running ? "Pause" : "Resume") \(entry.name)",
                            perform: mainAction) {
                    Image(systemName: entry.state == .running ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(entry.state == .running ? .blue : .green)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu { menu }
        .onHover { inside in
            hovering = inside
            if !inside { gate.clear() }
        }
    }

    @ViewBuilder
    private var menu: some View {
        switch entry.state {
        case .running:
            // A menu closing outside the row resets the gate, so a row shown busy offers
            // Force at once; its state line is the warning.
            Button(shownBusy || gate.armed == .pause ? "Force Pause" : "Pause") {
                if shownBusy { gate.clear(); model.pause(entry) } else { mainAction() }
            }
                .disabled(entry.neverFreeze)
        case .paused:
            Button("Resume", action: mainAction)
        case .sleeping:
            Button(waking ? "Waking..." : "Wake", action: mainAction).disabled(waking)
        }
        if entry.canDeepSleep {
            Button(shownBusy || gate.armed == .deepSleep ? "Force Deep Sleep" : "Deep Sleep") {
                if shownBusy { gate.clear(); deepSleepConfirmed() } else { deepSleepTapped() }
            }
        }
        if entry.state != .sleeping {
            Divider()
            Button("Auto-pause...") { showDetail = true }
            if let id = entry.bundleID, !id.isEmpty {
                Toggle("Never freeze", isOn: Binding(
                    get: { entry.neverFreeze },
                    set: { on in
                        if on { model.neverFreeze.append(id) } else { model.neverFreeze.removeAll { $0 == id } }
                    }))
            }
        }
    }

    /// Pause, Resume or Wake, for the button and the context menu alike.
    private func mainAction() {
        if entry.state == .running {
            gate.check(.pause, entry: entry, model: model) { model.pause(entry) }
        } else {
            model.resume(entry)
        }
    }

    private func deepSleepTapped() {
        gate.check(.deepSleep, entry: entry, model: model) { deepSleepConfirmed() }
    }

    private func deepSleepConfirmed() {
        // The seen flag only covers apps that restore their windows; for the rest
        // the warning is the only notice that windows may be lost.
        if PauseFlags.hasSeenDeepSleepWarning,
           DeepSleepController.canRestoreState(bundleID: entry.bundleID).kind == .good {
            model.deepSleep(entry)
        } else {
            showSleepWarning = true
        }
    }

    private var shownBusy: Bool {
        entry.pid.flatMap { model.appStates[$0] }.map { !$0.busy.isEmpty } ?? false
    }

    @ViewBuilder
    private var badge: some View {
        switch entry.state {
        case .running:
            if AppSettingsStore.shared.settings(for: entry.bundleID).autoPauseEnabled {
                Image(systemName: "timer").font(.system(size: 8)).foregroundStyle(.secondary)
                    .help("Auto-pause is on")
            }
        case .paused:
            stateTag("PAUSED", .blue)
        case .sleeping:
            stateTag("ASLEEP", .indigo)
        }
    }

    /// Resident RAM only: the memory held right now, which drops when an app is paused.
    /// Footprint barely moves (it counts compressed and swapped pages); the detail view has it.
    private var memoryLine: some View {
        HStack(spacing: 5) {
            if entry.state == .sleeping {
                Text("Quit, relaunches on Wake").font(.system(size: 10))
            } else {
                Text(MenuView.fmt(entry.resident)).font(.system(size: 10)).monospacedDigit()
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
        case .running: return "Pause \(entry.name): stop it, keep it in memory"
        case .paused: return "Resume \(entry.name)"
        case .sleeping: return "Wake \(entry.name): relaunch it and restore its windows"
        }
    }
}

private func stateTag(_ text: String, _ color: Color) -> some View {
    Text(text)
        .font(.system(size: 8, weight: .bold))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(color.opacity(0.2), in: Capsule())
        .foregroundStyle(color)
}

/// Busy or idle as of the last live pass, or the Force step's findings. Busy carries an
/// hourglass, not a warning color: orange is kept for Force and warnings.
private func liveStateLine(gateText: String?, state: LiveState?) -> some View {
    Group {
        if let busy = gateText ?? (state?.busy.isEmpty == false ? state?.busyText : nil) {
            Label(busy, systemImage: "hourglass").help(busy)
        } else if let state {
            Text(state.text())
        } else {
            Text(" ")
        }
    }
    .font(.system(size: 9))
    .foregroundStyle(.secondary)
    .lineLimit(1).truncationMode(.tail)
}

/// A Pause or Deep Sleep button that turns into Force while `gate` is armed for its action,
/// the same in app rows and the detail popover.
struct GatedButton<Content: View>: View {
    @ObservedObject var gate: BusyGate
    let action: BusyGate.Action
    let help: String
    let voiceOver: String
    let perform: () -> Void
    @ViewBuilder let label: () -> Content

    private var armed: Bool { gate.armed == action }

    var body: some View {
        Button(action: perform) {
            if armed {
                Label("Force", systemImage: action == .pause ? "pause.fill" : "moon.zzz.fill")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                    .foregroundStyle(.white)
            } else {
                label()
            }
        }
        .buttonStyle(.plain)
        .help(armed ? "\(gate.text ?? "Busy"). Click again to proceed anyway." : help)
        .accessibilityLabel(armed ? "Force: \(voiceOver)" : voiceOver)
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
