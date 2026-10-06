import AppKit
import ApplicationServices
import Foundation

/// Accessibility trust. Needed for window titles and focus tracking of other apps.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once per app identity) that leads to System Settings.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Titles of the app's windows, in AX order.
    static func windowTitles(pid: pid_t) -> [String] {
        let app = element(pid: pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap(title(of:))
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element(pid: pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value else { return nil }
        return title(of: window as! AXUIElement)
    }

    static func title(of window: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(window, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Title of the app's window at a point in top-left screen coordinates. Falls back to
    /// window frames when the hit test fails: the main process answers for frames, while a
    /// hit test into web content may need the (frozen) renderer.
    static func windowTitle(at point: CGPoint, pid: pid_t) -> String? {
        let app = element(pid: pid)
        var hit: AXUIElement?
        var value: CFTypeRef?
        if AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit,
           AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &value) == .success, let value {
            let window = value as! AXUIElement
            if let title = title(of: window) { return title }
        }
        // Front to back, so the first window containing the point is the one on top.
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { frame(of: $0)?.contains(point) == true }.flatMap(title(of:))
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// AX calls block until the target answers; a short timeout keeps a hung or frozen app
    /// from stalling the main thread for the default 6 s.
    static func element(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return app
    }
}

/// Reports the title of the app's focused window whenever focus moves between its windows, so a
/// frozen window can be thawed when the user clicks into it. The app's activation does not help
/// there: it is already active. Observe a process that is never frozen (VS Code's main process
/// owns all windows), since a stopped process sends no AX notifications.
@MainActor
final class WindowFocusObserver {
    let pid: pid_t
    private let onFocus: (String?) -> Void
    private var observer: AXObserver?

    /// Nil without Accessibility trust or when the app does not accept the observer.
    init?(pid: pid_t, onFocus: @escaping (String?) -> Void) {
        self.pid = pid
        self.onFocus = onFocus
        guard Accessibility.isTrusted else { return nil }
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<WindowFocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            let title = Accessibility.title(of: element)
            MainActor.assumeIsolated { observer.onFocus(title) }
        }, &created) == .success, let created else { return nil }

        let app = Accessibility.element(pid: pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Main window changes cover clicks that change the main but not the key window
        // (panels, sheets).
        let added = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification].filter {
            AXObserverAddNotification(created, app, $0 as CFString, refcon) == .success
        }
        guard !added.isEmpty else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    // The run loop source holds an unretained pointer to self.
    deinit {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}
