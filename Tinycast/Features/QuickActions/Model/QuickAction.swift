import Foundation

enum QuickAction: Hashable, Identifiable, Sendable {
    case builtIn(BuiltInQuickAction)
    case custom(CustomQuickAction)

    static let fixGrammar = QuickAction.builtIn(.fixGrammar)
    static let rewrite = QuickAction.builtIn(.rewrite)
    static let translate = QuickAction.builtIn(.translate)
    static let summarize = QuickAction.builtIn(.summarize)

    static let allBuiltIn: [QuickAction] = BuiltInQuickAction.allCases.map(QuickAction.builtIn)

    var id: String {
        switch self {
        case .builtIn(let action): return action.rawValue
        case .custom(let action): return action.entryID
        }
    }

    var builtInAction: BuiltInQuickAction? {
        guard case .builtIn(let action) = self else { return nil }
        return action
    }

    var customAction: CustomQuickAction? {
        guard case .custom(let action) = self else { return nil }
        return action
    }

    var title: String {
        switch self {
        case .builtIn(let action): return action.title
        case .custom(let action): return action.name
        }
    }

    var symbol: String {
        switch self {
        case .builtIn(let action): return action.symbol
        case .custom(let action): return action.symbol
        }
    }

    /// A custom action may always write back; only its own Replace choice decides whether it does.
    var replacesSelection: Bool { builtInAction?.replacesSelection ?? true }

    var rendersMarkdown: Bool { builtInAction.map { $0 == .summarize } ?? true }

    var usesTranslationFramework: Bool { builtInAction?.usesTranslationFramework ?? false }
}
