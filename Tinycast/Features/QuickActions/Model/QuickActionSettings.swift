import Foundation

struct QuickActionSettings: Equatable, Sendable {
    /// BCP-47, e.g. `es-419`. Empty means the Mac's own language.
    var targetLanguage: String = ""
    private(set) var instructionOverrides: [BuiltInQuickAction: String] = [:]

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
