import SwiftUI

/// Global busy conditions: which kinds of ongoing work keep an app from being paused
/// automatically and make a manual Pause or Deep Sleep ask for Force.
struct BusySettingsView: View {
    @ObservedObject var model: AppListModel

    private struct Draft: Identifiable {
        let id = UUID()
        var text: String
    }

    /// Edited patterns, including invalid ones; only valid ones reach the settings.
    @State private var drafts: [Draft] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A busy app is not auto-paused, and pausing or deep-sleeping it by hand needs a second click.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(BusyCondition.allCases, id: \.self) { condition in
                Toggle(condition.title, isOn: Binding(
                    get: { model.busySettings.enabled.contains(condition) },
                    set: { on in
                        if on { model.busySettings.enabled.insert(condition) } else { model.busySettings.enabled.remove(condition) }
                    }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }

            Stepper(value: $model.busySettings.cpuThresholdPercent, in: 0.5...100, step: 0.5) {
                Text("CPU above \(String(format: "%.1f", model.busySettings.cpuThresholdPercent))% of one core")
                    .font(.system(size: 11))
            }
            .disabled(!model.busySettings.enabled.contains(.cpu))

            Divider()

            Text("Commands (regular expressions on the full command line)")
                .font(.system(size: 11, weight: .medium))
            ForEach($drafts) { $draft in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        TextField("pattern", text: $draft.text)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))
                            .onChange(of: draft.text) { _, _ in savePatterns() }
                        Button {
                            drafts.removeAll { $0.id == draft.id }
                            savePatterns()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                        .accessibilityLabel("Remove pattern \(draft.text)")
                    }
                    if let error = BusySettings.patternError(draft.text) {
                        Text("\(error), not saved").font(.system(size: 9)).foregroundStyle(.red)
                    }
                }
            }
            HStack {
                Button {
                    drafts.append(Draft(text: ""))
                } label: {
                    Label("Add", systemImage: "plus.circle").font(.caption)
                }
                Spacer()
                Button("Restore defaults") {
                    drafts = BusySettings.defaultPatterns.map { Draft(text: $0) }
                    savePatterns()
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(!model.busySettings.enabled.contains(.processes))
        }
        .padding(20)
        .onAppear { drafts = model.busySettings.patterns.map { Draft(text: $0) } }
    }

    private func savePatterns() {
        model.busySettings.patterns = drafts.map(\.text).filter { BusySettings.patternError($0) == nil }
    }
}
