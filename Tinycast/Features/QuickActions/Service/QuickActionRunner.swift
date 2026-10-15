import AppKit

/// Reads the text a quick action works on; the reply and any write-back belong to Quick AI.
@MainActor
final class QuickActionRunner {
    /// The ceiling lives here, not at the provider, where it returns as an opaque context error.
    static let maxSelectionBytes = 32_768

    /// A borrowed ⌘C synthesises a keystroke into somebody's app, so it is never the first try.
    static func selection(
        in targetApp: NSRunningApplication?, using injector: TextInjector
    ) async throws -> String {
        // A shortcut press is an explicit gesture, so it may prompt, as snippet expansion does.
        guard Permissions.ensureAccessibility() else { throw QuickActionFailure.needsAccessibility }
        guard let targetApp,
            targetApp.bundleIdentifier != Bundle.main.bundleIdentifier
        else { throw QuickActionFailure.noTarget }

        let reported = AccessibilityText.read(in: targetApp)
        if case .text(let text) = reported { return try accepted(text) }
        if let copied = await injector.copySelection(from: targetApp) {
            return try accepted(copied)
        }
        // Only when Accessibility saw a text element is "nothing is selected" the honest answer.
        throw reported == .empty
            ? QuickActionFailure.noSelection
            : .unreadableApp(targetApp.localizedName ?? "That app")
    }

    static func accepted(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuickActionFailure.noSelection
        }
        guard text.utf8.count <= maxSelectionBytes else { throw QuickActionFailure.tooLong }
        return text
    }
}
