import Foundation

/// What a run shows and where its failures land, decided before anything is read.
enum QuickActionCapturePlan {
    static let capturingMessage = "Gathering selected text…"

    static func previews(replacesOnly: Bool) -> Bool { !replacesOnly }

    static func writesBack(replacesSelection: Bool, fromPage: Bool) -> Bool {
        replacesSelection && !fromPage
    }

    static func silently(writesBack: Bool, replacesOnly: Bool) -> Bool {
        writesBack && replacesOnly
    }

    static func sourceName(fromPage: Bool) -> String {
        fromPage ? "Page text" : "Selected text"
    }

    enum ErrorDestination: Equatable, Sendable {
        case chat
        case pill
        case dialog
    }

    static func destination(for failure: QuickActionFailure, previews: Bool) -> ErrorDestination {
        guard previews else { return failure.opensAccessibilitySettings ? .dialog : .pill }
        return .chat
    }

    static func destinationForPageFailure(previews: Bool) -> ErrorDestination {
        previews ? .chat : .pill
    }

    struct ChatSnapshot: Equatable, Sendable {
        let sessionID: UUID
        let stagingGeneration: Int
        let messageCount: Int
        let isStreaming: Bool
        let pendingAttachmentCount: Int
    }

    struct UIState: Equatable, Sendable {
        let mine: Int
        let generation: Int
        let cancelled: Bool
        let paletteShowingAI: Bool
        let aiEnabled: Bool
        let quickActionsEnabled: Bool
    }

    /// True only while the prepared chat is still the one on screen and empty.
    static func allowsStaging(
        prepared: ChatSnapshot, current: ChatSnapshot, ui: UIState, previews: Bool
    ) -> Bool {
        guard !ui.cancelled, ui.mine == ui.generation else { return false }
        guard ui.aiEnabled, ui.quickActionsEnabled else { return false }
        guard current.sessionID == prepared.sessionID else { return false }
        guard current.stagingGeneration == prepared.stagingGeneration else { return false }
        guard !current.isStreaming, current.messageCount == 0 else { return false }
        guard current.pendingAttachmentCount == 0 else { return false }
        if previews { guard ui.paletteShowingAI else { return false } }
        return true
    }
}
