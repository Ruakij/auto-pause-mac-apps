import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !PauseFlags.hasCompletedOnboarding {
            // Give the status item a moment to appear so the "look up here" hint lands
            // on a menu bar that already shows our icon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never strand frozen apps or windows: resume everything on quit.
        for rec in PausedStore.shared.resumeOrder {
            // A window record's pid may belong to another process by now.
            if rec.ownerPid == nil || rec.isLive { ProcessControl.resumeTree(root: rec.pid) }
            PausedStore.shared.remove(pid: rec.pid)
        }
    }

    func showOnboarding() {
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            PauseFlags.hasCompletedOnboarding = true
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        })
        window.isReleasedWhenClosed = false
        onboardingWindow = window

        // An LSUIElement app is not activated by default, so ask for focus explicitly.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct PauseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppListModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.pausedCount + model.frozenWindowCount > 0 ? "pause.circle.fill" : "pause.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model, showOnboarding: { appDelegate.showOnboarding() })
        }
    }
}
