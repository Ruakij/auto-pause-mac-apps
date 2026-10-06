import AppKit
import SwiftUI

/// The Settings window (Cmd-, from the panel). A window rather than popover pages: the regex
/// list and the app lists outgrow a popover, which also closes as soon as focus moves.
struct SettingsView: View {
    @ObservedObject var model: AppListModel
    let showOnboarding: () -> Void

    var body: some View {
        TabView {
            GeneralSettingsView(showOnboarding: showOnboarding)
                .tabItem { Label("General", systemImage: "gearshape") }
            BusySettingsView(model: model)
                .tabItem { Label("Busy Conditions", systemImage: "hourglass") }
            NeverFreezeSettingsView(model: model)
                .tabItem { Label("Never Freeze", systemImage: "lock") }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettingsView: View {
    let showOnboarding: () -> Void
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    /// Re-read on activation: trust is granted in System Settings while this app runs.
    @State private var trusted = Accessibility.isTrusted

    var body: some View {
        Form {
            Section {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wants in
                        if case .failure(let error) = LaunchAtLogin.set(wants) {
                            loginError = "Could not change the login item: \(error.localizedDescription)"
                            launchAtLogin = LaunchAtLogin.isEnabled
                        } else {
                            loginError = nil
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                if LaunchAtLogin.requiresApproval {
                    Button("Approve in System Settings...") { LaunchAtLogin.openLoginItemsSettings() }
                }
            } footer: {
                Text("Auto-pause and window thawing only work while Auto Pause runs.")
            }

            Section {
                LabeledContent("Accessibility") {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings...") { Accessibility.openSettings() }
                    }
                }
            } footer: {
                Text("Needed to pause single VS Code windows and to resume a paused window when it is clicked. Without it, Window Pause stays off.")
            }

            Section {
                Button("Show the Walkthrough Again") { showOnboarding() }
                Link("Source and Docs on GitHub", destination: URL(string: "https://github.com/fazalrshah/auto-pause-mac-apps")!)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            trusted = Accessibility.isTrusted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = Accessibility.isTrusted
        }
    }
}
