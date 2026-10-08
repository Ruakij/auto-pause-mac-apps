import AppKit
import ApplicationServices

/// Accessibility trust, opt-in. It lets a paused app thaw when the user goes back to it in a way
/// that the stopped app would otherwise have to answer itself, such as a Dock click.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Distributed notification posted when any app's Accessibility trust changes;
    /// `isTrusted` reads the new value only a moment later.
    static let trustChangedNotification = Notification.Name("com.apple.accessibility.api")

    /// Shows the system prompt (once per app identity) that leads to System Settings.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// AX calls block until the target answers; a short timeout keeps a hung or frozen app
    /// from stalling the main thread for the default 6 s. Never point one at a stopped app.
    static func element(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return app
    }

    /// Bundle URL of the application Dock tile at a point in top-left screen coordinates; nil
    /// when the point is not on one. Only the Dock is asked, and only when the point lies in one
    /// of its windows, so a click elsewhere costs no AX call.
    static func dockApplicationURL(at point: CGPoint) -> URL? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let dockPid = dock.processIdentifier
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let onDock = windows.contains { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == dockPid,
                  info[kCGWindowLayer as String] as? Int == dockLevel,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.contains(point)
        }
        guard onDock else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(element(pid: dockPid), Float(point.x), Float(point.y), &hit) == .success,
              let hit, string(hit, kAXSubroleAttribute) == "AXApplicationDockItem" else { return nil }
        var url: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXURLAttribute as CFString, &url) == .success else { return nil }
        return url as? URL
    }

    /// Title of one window, answered by the app's main process.
    struct WindowText {
        let element: AXUIElement
        let title: String?
    }

    /// The app's focused window and its other windows. AX lists only the windows of the
    /// current Space; windows on other Spaces are missing from `others`. Nil when the app has
    /// no focused window, does not answer or is stopped.
    static func windowTexts(pid: pid_t) -> (focused: WindowText, others: [WindowText])? {
        guard !ProcessControl.isStopped(pid) else { return nil }
        let app = element(pid: pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let focusedWindow = focused as! AXUIElement
        var list: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list)
        let others = ((list as? [AXUIElement]) ?? []).filter { !CFEqual($0, focusedWindow) }
        return (text(of: focusedWindow), others.map(text))
    }

    private static func text(of window: AXUIElement) -> WindowText {
        // The timeout is per element; a new one starts with the default 6 s.
        AXUIElementSetMessagingTimeout(window, 0.25)
        return WindowText(element: window, title: string(window, kAXTitleAttribute))
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Top-left screen coordinates (AX, CGWindowList) of the pointer; AppKit counts from the
    /// bottom left of the primary screen.
    static var pointerLocation: CGPoint {
        let location = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: location.x, y: height - location.y)
    }
}
