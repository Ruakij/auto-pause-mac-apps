import SwiftUI

/// Shown before a Deep Sleep: always for apps that may not restore their windows, once for the rest,
/// so "this actually quits the app" is never a surprise.
struct DeepSleepWarningView: View {
    let entry: AppEntry
    let status: RestoreStatus
    let onCancel: () -> Void
    let onProceed: () -> Void

    @State private var restoreEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deep Sleep \(entry.name)?")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Frees all of its memory — including swap")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Deep Sleep **actually quits** the app, unlike Pause, which only stops it. "
                 + "That releases 100% of its memory instead of only part of it. "
                 + "Waking it relaunches the app and restores your windows.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: statusIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
                Text(status.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))

            if status.kind == .fixable && !restoreEnabled {
                Button {
                    if let id = entry.bundleID {
                        DeepSleepController.enableStateRestoration(bundleID: id)
                        restoreEnabled = true
                    }
                } label: {
                    Label("Turn on window restore for \(entry.name)", systemImage: "macwindow.badge.plus")
                        .font(.caption)
                }
            } else if restoreEnabled {
                Label("Window restore turned on", systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green)
            }

            Text("Your work is safe: apps that autosave will save before quitting, and apps that don't will ask you what to do and stay open if you cancel. Nothing is ever force-quit.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Deep Sleep") {
                    PauseFlags.hasSeenDeepSleepWarning = true
                    onProceed()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private var statusIcon: String {
        switch status.kind {
        case .good: return "checkmark.circle.fill"
        case .fixable: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status.kind {
        case .good: return .green
        case .fixable: return .orange
        case .unknown: return .yellow
        }
    }
}
