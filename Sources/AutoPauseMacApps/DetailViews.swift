import SwiftUI

/// Lightweight line+area chart drawn from raw samples — no framework dependency.
struct SparklineView: View {
    let history: [UInt64]
    var color: Color = .blue
    var lineWidth: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            guard history.count > 1 else { return }
            // From 0, not the window's own minimum, so noise stays small.
            let maxV = Double(max(history.max() ?? 1, 1))

            var line = Path()
            for (i, v) in history.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(history.count - 1)
                let norm = Double(v) / maxV
                let y = size.height * (1 - CGFloat(norm))
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.15)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
        }
    }
}

/// Per-app detail popover: memory history graph + idle auto-pause settings.
struct AppDetailView: View {
    let entry: AppEntry
    @ObservedObject var model: AppListModel
    @State private var settings: AppSettings
    @StateObject private var gate = BusyGate()

    init(entry: AppEntry, model: AppListModel) {
        self.entry = entry
        self.model = model
        _settings = State(initialValue: AppSettingsStore.shared.settings(for: entry.bundleID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let icon = entry.icon {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).font(.system(size: 14, weight: .semibold))
                    Text("\(MenuView.fmt(entry.resident)) in RAM, \(MenuView.fmt(entry.footprint)) footprint")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if entry.history.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory over last \(entry.history.count * 3)s")
                        .font(.caption2).foregroundStyle(.tertiary)
                    SparklineView(history: entry.history, color: .blue, lineWidth: 2)
                        .frame(height: 90)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Text("Collecting memory history...")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: 90)
            }

            Divider()

            Toggle("Auto-pause when idle", isOn: $settings.autoPauseEnabled)
                .toggleStyle(.switch)
                .onChange(of: settings.autoPauseEnabled) { _, _ in save() }
                .disabled(entry.neverFreeze)
                .help(entry.neverFreeze ? "On the Never freeze list" : "")

            if settings.autoPauseEnabled && !entry.neverFreeze {
                Stepper("After \(settings.autoPauseMinutes) min in background",
                        value: $settings.autoPauseMinutes, in: 1...180)
                    .font(.caption)
                    .onChange(of: settings.autoPauseMinutes) { _, _ in save() }
            }

            HStack {
                if let busyText = gate.text {
                    Label(busyText, systemImage: "hourglass").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if entry.state == .running && entry.neverFreeze {
                    Label("On the Never freeze list", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    let running = entry.state == .running
                    GatedButton(gate: gate, action: .pause, help: "\(running ? "Pause" : "Resume") \(entry.name)",
                                voiceOver: "\(running ? "Pause" : "Resume") \(entry.name)") {
                        if running {
                            gate.check(.pause, entry: entry, model: model) { model.pause(entry) }
                        } else {
                            model.resume(entry)
                        }
                    } label: {
                        Label(running ? "Pause" : "Resume", systemImage: running ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(running ? .blue : .green)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280)
        .onDisappear { gate.clear() }
    }

    private func save() {
        guard let id = entry.bundleID, !id.isEmpty else { return }
        settings.bundleID = id
        AppSettingsStore.shared.update(settings)
        model.rescheduleAutoPause()
    }
}

/// Filled system-wide usage graph, shown prominently in the main panel — same idea as a
/// classic menu-bar utility's history chart, but drawn with our own gradient-fill style.
struct UsageAreaChart: View {
    let history: [UInt64]
    /// The scale denominator (e.g. total system RAM). Plotting against this fixed value,
    /// rather than the window's own min/max, keeps small real fluctuations looking small
    /// instead of stretching them into a dramatic zigzag.
    let totalBytes: UInt64
    var accent: Color = .blue

    var body: some View {
        Canvas { context, size in
            guard history.count > 1, totalBytes > 0 else { return }

            var line = Path()
            for (i, v) in history.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(history.count - 1)
                let norm = min(1, Double(v) / Double(totalBytes))
                let y = size.height * (1 - CGFloat(norm))
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            let gradient = Gradient(colors: [accent.opacity(0.55), accent.opacity(0.06)])
            context.fill(fill, with: .linearGradient(
                gradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(accent), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(height: 64)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
