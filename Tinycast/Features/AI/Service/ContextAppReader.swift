import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads the app behind the palette or chat: metadata plus bounded accessible text. Off-main.
nonisolated enum ContextAppReader {
    /// Captured on-main before Tinycast takes focus, so the target can never be the composer.
    struct Snapshot: Sendable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let name: String

        var sourceKey: String {
            if let bundleIdentifier, !bundleIdentifier.isEmpty { return "app:\(bundleIdentifier)" }
            return "app:pid-\(processIdentifier)"
        }
    }

    struct Read: Sendable {
        let selection: String?
        /// Focused text when nothing is selected and the caller asked for the whole window.
        let value: String?
        let windowTitle: String?
        /// Secure input or a secure field refused the text; the title may still be quoted.
        let skippedSecureInput: Bool
    }

    static let maxValueChars = 4_000
    static let maxTitleChars = 120

    /// Nil for Tinycast itself: app context never means the composer asking about itself.
    static func snapshot(of app: NSRunningApplication?) -> Snapshot? {
        guard let app, app.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return nil }
        if let bundle = app.bundleIdentifier, bundle.hasPrefix("com.tinycast.app") { return nil }
        return Snapshot(
            processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? "Unknown App")
    }

    /// Blocking AX walks stay here, never on the main actor; every call carries its own timeout.
    static func read(_ snapshot: Snapshot, wantsFull: Bool) -> Read {
        let empty = Read(selection: nil, value: nil, windowTitle: nil, skippedSecureInput: false)
        if IsSecureEventInputEnabled() {
            return Read(selection: nil, value: nil, windowTitle: nil, skippedSecureInput: true)
        }
        guard
            let app = NSRunningApplication(processIdentifier: snapshot.processIdentifier),
            !app.isTerminated, app.bundleIdentifier == snapshot.bundleIdentifier
        else { return empty }
        let application = AXUIElementCreateApplication(snapshot.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)
        AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let element = focusedElement(in: application) else { return empty }
        if isSecure(element) {
            return Read(
                selection: nil, value: nil, windowTitle: windowTitle(in: application),
                skippedSecureInput: true)
        }
        let selection = selectedText(in: element)
        let value =
            wantsFull && selection == nil
            ? valueText(in: element) : nil
        return Read(
            selection: selection, value: value, windowTitle: windowTitle(in: application),
            skippedSecureInput: false)
    }

    private static func focusedElement(in application: AXUIElement) -> AXUIElement? {
        var focusedValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
            let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focusedValue as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 1)
        return element
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
            let role = role as? String
        else { return false }
        return role.localizedCaseInsensitiveContains("secure")
    }

    private static func selectedText(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
            == .success,
            let text = value as? String, !text.isEmpty
        {
            return text
        }
        var range: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextMarkerRangeAttribute as CFString, &range) == .success,
            let range, CFGetTypeID(range) == AXTextMarkerRangeGetTypeID()
        else { return nil }
        var web: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForTextMarkerRangeParameterizedAttribute as CFString, range,
                &web) == .success,
            let text = web as? String, !text.isEmpty
        else { return nil }
        return text
    }

    private static func valueText(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
            let text = value as? String, !text.isEmpty
        else { return nil }
        return String(text.prefix(maxValueChars))
    }

    private static func windowTitle(in application: AXUIElement) -> String? {
        guard let element = focusedElement(in: application) else { return nil }
        var window: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window)
                == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let windowElement = unsafeDowncast(window as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(windowElement, 1)
        var title: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &title)
                == .success,
            let text = title as? String, !text.isEmpty
        else { return nil }
        return String(text.prefix(maxTitleChars))
    }
}
