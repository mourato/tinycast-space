import Foundation

struct QuickActionSettings: Equatable, Sendable {
    /// BCP-47, e.g. `es-419`. Empty means the Mac's own language.
    var targetLanguage: String = ""
    private(set) var instructionOverrides: [BuiltInQuickAction: String] = [:]
    /// Built-in actions that write their reply back without opening Quick AI. Absent means Quick AI.
    private(set) var replaceOnlyActions: Set<BuiltInQuickAction> = []

    /// Only the reader's choice on a custom action's record; a built-in one lives here.
    func replacesOnly(_ action: QuickAction) -> Bool {
        switch action {
        case .builtIn(let builtIn): return replacesOnly(builtIn)
        case .custom(let custom): return !custom.previewsResult
        }
    }

    func replacesOnly(_ action: BuiltInQuickAction) -> Bool {
        replaceOnlyActions.contains(action)
    }

    /// Summarize has nothing to write back, so it can never be told to.
    mutating func setReplacesOnly(_ replacesOnly: Bool, for action: BuiltInQuickAction) {
        guard action.replacesSelection else { return }
        if replacesOnly {
            replaceOnlyActions.insert(action)
        } else {
            replaceOnlyActions.remove(action)
        }
    }

    func instructionOverride(for action: QuickAction) -> String? {
        action.builtInAction.flatMap(instructionOverride)
    }

    func instructionOverride(for action: BuiltInQuickAction) -> String? {
        instructionOverrides[action]
    }

    mutating func setInstructionOverride(_ instructions: String?, for action: BuiltInQuickAction) {
        guard !action.usesTranslationFramework else { return }
        instructionOverrides[action] = instructions
    }

    var storedReplaceOnlyActions: [String] {
        get { replaceOnlyActions.map(\.rawValue).sorted() }
        set {
            replaceOnlyActions = Set(
                newValue.compactMap(BuiltInQuickAction.init(rawValue:))
                    .filter(\.replacesSelection))
        }
    }

    /// Round-trips through `UserDefaults`; an unknown key is an action that no longer exists.
    var storedInstructionOverrides: [String: String] {
        get { Dictionary(uniqueKeysWithValues: instructionOverrides.map { ($0.rawValue, $1) }) }
        set {
            instructionOverrides = Dictionary(
                uniqueKeysWithValues: newValue.compactMap { key, value in
                    guard let action = BuiltInQuickAction(rawValue: key),
                        !action.usesTranslationFramework
                    else { return nil }
                    return (action, value)
                })
        }
    }
}
