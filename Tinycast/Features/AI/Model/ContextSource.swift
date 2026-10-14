import Foundation

/// One place a chat may quote. Pure, so a harness pins it rather than a pane.
enum ContextSource: String, CaseIterable, Identifiable, Sendable {
    case browserTabs
    case apps
    case actions
    case integrations
    case tools
    case memoryGroups
    case variables

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browserTabs: return "Browser tabs"
        case .apps: return "Apps"
        case .actions: return "Actions"
        case .integrations: return "Integrations"
        case .tools: return "Tools"
        case .memoryGroups: return "Memory groups"
        case .variables: return "Variables"
        }
    }

    var defaultPriority: Double {
        switch self {
        case .browserTabs: return 1.0
        case .apps: return 0.9
        case .actions: return 0.8
        case .integrations: return 0.7
        case .tools: return 0.6
        case .memoryGroups: return 0.5
        case .variables: return 0.4
        }
    }

    /// Memory groups and variables have no engine in this build, so they offer no rows.
    var isAvailable: Bool {
        switch self {
        case .memoryGroups, .variables: return false
        default: return true
        }
    }

    var unavailableReason: String? {
        switch self {
        case .memoryGroups: return "Memory groups aren't available in this build."
        case .variables: return "Variables aren't available in this build."
        default: return nil
        }
    }

    /// Priorities stay inside the unit interval; anything else repairs to the default.
    static func normalized(priority: Double, for source: ContextSource) -> Double {
        guard priority.isFinite, priorityRange.contains(priority) else {
            return source.defaultPriority
        }
        return priority
    }

    static let priorityRange = 0.0...1.0

    var menuSymbol: String {
        switch self {
        case .browserTabs: return "globe"
        case .apps: return "app.window"
        case .actions: return "wand.and.sparkles"
        case .integrations: return "puzzlepiece.extension"
        case .tools: return "wrench.and.screwdriver"
        case .memoryGroups: return "brain"
        case .variables: return "curlybraces"
        }
    }
}
