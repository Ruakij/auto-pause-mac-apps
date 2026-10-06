import AppKit
import SwiftUI

/// Settings > Never freeze: apps that nothing freezes, with no Force. Deep Sleep stays available.
struct NeverFreezeSettingsView: View {
    @ObservedObject var model: AppListModel
    let onBack: () -> Void

    private let rowHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                Text("Never freeze").font(.system(size: 13, weight: .semibold))
            }
            Text("These apps are never paused: not automatically, not by Free Up Memory and not by hand, and there is no Force. Deep Sleep stays available.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.neverFreeze.isEmpty {
                Text("The list is empty.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.neverFreeze, id: \.self) { row($0) }
                    }
                }
                .frame(height: min(CGFloat(model.neverFreeze.count) * rowHeight, 330))
            }

            HStack {
                Menu("Add running app...") {
                    ForEach(addable, id: \.bundleID) { entry in
                        Button(entry.name) {
                            if let id = entry.bundleID { model.neverFreeze.append(id) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(addable.isEmpty)
                Spacer()
                Button("Restore defaults") { model.neverFreeze = NeverFreezeList.defaults }
                    .buttonStyle(.plain)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 320)
    }

    /// Listed apps that are not on the list yet, each bundle ID once.
    private var addable: [AppEntry] {
        var seen = Set(model.neverFreeze)
        return model.entries
            .filter { $0.pid != nil && $0.bundleID.map { seen.insert($0).inserted } == true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func row(_ id: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        return HStack(spacing: 6) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 16, height: 16)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                    .font(.system(size: 11))
            } else {
                Image(systemName: "app.dashed").frame(width: 16, height: 16).foregroundStyle(.tertiary)
                Text(id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.neverFreeze.removeAll { $0 == id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .lineLimit(1)
        .frame(height: rowHeight)
    }
}
