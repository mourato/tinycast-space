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
        let isBrowser: Bool

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
        /// Accessibility trust is missing, so nothing was read; the UI explains the grant.
        let accessDenied: Bool
        /// The focused window moved mid-read, so the text is dropped, never half-quoted.
        let windowChanged: Bool
        /// The value or selection was cut to the bound before staging saw it.
        let isTruncated: Bool

        init(
            selection: String? = nil, value: String? = nil, windowTitle: String? = nil,
            skippedSecureInput: Bool = false, accessDenied: Bool = false,
            windowChanged: Bool = false, isTruncated: Bool = false
        ) {
            self.selection = selection
            self.value = value
            self.windowTitle = windowTitle
            self.skippedSecureInput = skippedSecureInput
            self.accessDenied = accessDenied
            self.windowChanged = windowChanged
            self.isTruncated = isTruncated
        }
    }

    static let maxValueChars = 4_000
    static let maxTitleChars = 120

    static var browserBundleURLs: Set<URL> {
        guard let probe = URL(string: "https://example.invalid") else { return [] }
        return Set(NSWorkspace.shared.urlsForApplications(toOpen: probe).map(\.standardizedFileURL))
    }

    /// Nil for Tinycast itself: app context never means the composer asking about itself.
    static func snapshot(of app: NSRunningApplication?) -> Snapshot? {
        guard let app, app.processIdentifier != NSRunningApplication.current.processIdentifier
        else { return nil }
        if let bundle = app.bundleIdentifier, bundle.hasPrefix("com.tinycast.app") { return nil }
        let handlesWebURLs = app.bundleURL.map { browserBundleURLs.contains($0.standardizedFileURL) } ?? false
        let isBrowser = ContextBrowser.isSupported(bundleID: app.bundleIdentifier) || handlesWebURLs
        return Snapshot(
            processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? "Unknown App", isBrowser: isBrowser)
    }

    /// Blocking AX walks stay here, never on the main actor; every call carries its own timeout.
    @concurrent static func read(_ snapshot: Snapshot) async -> Read {
        let empty = Read()
        guard !snapshot.isBrowser, !Task.isCancelled else { return empty }
        if IsSecureEventInputEnabled() {
            return Read(skippedSecureInput: true)
        }
        guard AXIsProcessTrusted() else { return Read(accessDenied: true) }
        guard
            let app = NSRunningApplication(processIdentifier: snapshot.processIdentifier),
            !app.isTerminated, app.bundleIdentifier == snapshot.bundleIdentifier
        else { return empty }
        let application = AXUIElementCreateApplication(snapshot.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)
        AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard !Task.isCancelled, let element = focusedElement(in: application) else { return empty }
        if isSecure(element) {
            return Read(
                windowTitle: windowTitle(in: application), skippedSecureInput: true)
        }
        guard let before = windowElement(for: element) else { return empty }
        let (selection, selectionCut) = selectedText(in: element)
        let (value, valueCut) = valueText(in: element)
        guard windowStill(before, in: application) else { return Read(windowChanged: true) }
        return Read(
            selection: selection, value: value, windowTitle: windowTitle(in: application),
            isTruncated: selectionCut || valueCut)
    }

    private static func focusedElement(in application: AXUIElement) -> AXUIElement? {
        guard !Task.isCancelled else { return nil }
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
        guard !Task.isCancelled else { return true }
        var role: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
            let role = role as? String
        else { return false }
        if role.localizedCaseInsensitiveContains("secure") { return true }
        guard !Task.isCancelled else { return true }
        var subrole: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
                == .success,
            let subrole = subrole as? String
        else { return false }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    private static func selectedText(in element: AXUIElement) -> (String?, Bool) {
        if let direct = selectedString(in: element) { return boundedSelection(direct) }
        guard !Task.isCancelled else { return (nil, false) }
        var range: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextMarkerRangeAttribute as CFString, &range) == .success,
            let range, CFGetTypeID(range) == AXTextMarkerRangeGetTypeID()
        else { return (nil, false) }
        var web: CFTypeRef?
        guard
            !Task.isCancelled,
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForTextMarkerRangeParameterizedAttribute as CFString, range,
                &web) == .success,
            let text = web as? String, !text.isEmpty
        else { return (nil, false) }
        return boundedSelection(text)
    }

    private static func selectedString(in element: AXUIElement) -> String? {
        guard !Task.isCancelled else { return nil }
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
                == .success,
            let text = value as? String, !text.isEmpty
        else { return nil }
        return text
    }

    private static func boundedSelection(_ text: String) -> (String?, Bool) {
        guard text.count > maxValueChars else { return (text, false) }
        return (String(text.prefix(maxValueChars)), true)
    }

    private static func valueText(in element: AXUIElement) -> (String?, Bool) {
        guard !Task.isCancelled else { return (nil, false) }
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
            let text = value as? String, !text.isEmpty
        else { return (nil, false) }
        guard text.count > maxValueChars else { return (text, false) }
        return (String(text.prefix(maxValueChars)), true)
    }

    /// The focused element's window, so a mid-read window switch drops the quote, never mixes it.
    private static func windowElement(for element: AXUIElement) -> AXUIElement? {
        guard !Task.isCancelled else { return nil }
        var window: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window)
                == .success,
            let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(window as AnyObject, to: AXUIElement.self)
    }

    private static func windowStill(_ before: AXUIElement, in application: AXUIElement) -> Bool {
        guard let element = focusedElement(in: application),
            let after = windowElement(for: element)
        else { return false }
        return CFEqual(before, after)
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
        guard !Task.isCancelled else { return nil }
        var title: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &title)
                == .success,
            let text = title as? String, !text.isEmpty
        else { return nil }
        return String(text.prefix(maxTitleChars))
    }
}
