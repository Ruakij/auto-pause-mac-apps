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

    /// Title of the app's focused window; nil when it has none, does not answer or is stopped.
    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard !ProcessControl.isStopped(pid) else { return nil }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element(pid: pid), kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        // The timeout is per element; a new one starts with the default 6 s.
        let element = window as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        return string(element, kAXTitleAttribute)
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
