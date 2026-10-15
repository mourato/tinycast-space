import Foundation

enum BuiltInQuickAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case fixGrammar
    case rewrite
    case translate
    case summarize

    var id: String { rawValue }

    var title: String { titleResource.resolved() }

    /// A resource, so a launcher command named after it keeps the English name searchable.
    var titleResource: LocalizedStringResource {
        switch self {
        case .fixGrammar: return "Fix Grammar"
        case .rewrite: return "Rewrite"
        case .translate: return "Translate"
        case .summarize: return "Summarize"
        }
    }

    var symbol: String {
        switch self {
        case .fixGrammar: return "textformat"
        case .rewrite: return "wand.and.sparkles"
        case .translate: return "translate"
        case .summarize: return "text.line.3.summary"
        }
    }

    var progressTitle: String {
        switch self {
        case .fixGrammar: return "Fixing Grammar…"
        case .rewrite: return "Rewriting…"
        case .translate: return "Translating…"
        case .summarize: return "Summarizing…"
        }
    }

    /// A summary is read, never written over the reader's text.
    var replacesSelection: Bool { self != .summarize }

    var usesTranslationFramework: Bool { self == .translate }
}
