import AppKit
import SwiftUI

/// Settings > Never Freeze: apps that nothing freezes, with no Force (Deep Sleep stays
/// available).
struct NeverFreezeSettingsView: View {
    @ObservedObject var model: AppListModel

    private let rowHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("These apps are never paused: not automatically, not by Free Up Memory and not by hand, and there is no Force. Deep Sleep stays available.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            list(model.neverFreeze) { id in model.neverFreeze.removeAll { $0 == id } }

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
        .padding(20)
    }

    /// Listed apps that are not on the list yet, each bundle ID once.
    private var addable: [AppEntry] {
        var seen = Set(model.neverFreeze)
        return model.entries
            .filter { $0.pid != nil && $0.bundleID.map { seen.insert($0).inserted } == true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private func list(_ ids: [String], remove: @escaping (String) -> Void) -> some View {
        if ids.isEmpty {
            Text("The list is empty.").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ids, id: \.self) { row($0, remove: remove) }
                }
            }
            .frame(height: min(CGFloat(ids.count) * rowHeight, 220))
        }
    }

    private func row(_ id: String, remove: @escaping (String) -> Void) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        return HStack(spacing: 6) {
            if let url, let name {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 16, height: 16)
                Text(name).font(.system(size: 11))
            } else {
                Image(systemName: "app.dashed").frame(width: 16, height: 16).foregroundStyle(.tertiary)
                Text(id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                remove(id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove \(name ?? id)")
        }
        .lineLimit(1)
        .frame(height: rowHeight)
    }
}
