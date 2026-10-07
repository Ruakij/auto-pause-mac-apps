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
        // Never strand frozen apps: resume everything on quit.
        for rec in PausedStore.shared.records {
            ProcessControl.resumeTree(root: rec.pid)
            PausedStore.shared.remove(pid: rec.pid)
        }
    }

    @MainActor
    func showOnboarding() {
        if let existing = onboardingWindow {
            WindowPlacement.present(existing)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            PauseFlags.hasCompletedOnboarding = true
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        })
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        WindowPlacement.present(window)
    }
}

/// Shows this app's windows where the user is: AppKit and SwiftUI reuse a closed window at its
/// old frame, and activation follows a window to its old Space.
@MainActor
enum WindowPlacement {
    /// Set by `WindowAccessor` in `SettingsView`; SwiftUI offers no handle to that window.
    static weak var settingsWindow: NSWindow?

    /// Shows `window` on the active Space, centered on `screen` (default: the screen under the
    /// pointer) unless it is already visible there, so a position dragged to is kept.
    static func present(_ window: NSWindow, on screen: NSScreen? = nil) {
        // Moves the window to the active Space but keeps its frame, so the screen is set below.
        window.collectionBehavior.insert(.moveToActiveSpace)
        let target = screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let target, window.screen != target || !window.isVisible {
            let vf = target.visibleFrame
            window.setFrameOrigin(NSPoint(x: vf.midX - window.frame.width / 2,
                                          y: vf.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        // An LSUIElement app is not active, so the window would open behind the frontmost app.
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
            Image(systemName: model.pausedCount > 0 ? "pause.circle.fill" : "pause.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model, showOnboarding: { appDelegate.showOnboarding() })
        }
    }
}
