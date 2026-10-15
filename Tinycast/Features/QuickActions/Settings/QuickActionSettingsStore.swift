import Foundation
import Observation

/// Apart from `AISettingsStore`: a peer of chat, with its own switch and settings pane.
@MainActor
@Observable
final class QuickActionSettingsStore {
    private let defaults: UserDefaults

    var settings: QuickActionSettings {
        didSet { persistSettings() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = QuickActionSettings()
        loaded.targetLanguage =
            defaults.string(forKey: AppSettingsKey.quickActionLanguage.rawValue) ?? ""
        loaded.storedInstructionOverrides =
            defaults.dictionary(forKey: AppSettingsKey.quickActionInstructions.rawValue)
            as? [String: String] ?? [:]
        loaded.storedReplaceOnlyActions =
            defaults.stringArray(forKey: AppSettingsKey.quickActionReplaceOnly.rawValue) ?? []
        settings = loaded
    }

    private func persistSettings() {
        defaults.set(settings.targetLanguage, forKey: AppSettingsKey.quickActionLanguage.rawValue)
        defaults.set(
            settings.storedInstructionOverrides,
            forKey: AppSettingsKey.quickActionInstructions.rawValue)
        defaults.set(
            settings.storedReplaceOnlyActions, forKey: AppSettingsKey.quickActionReplaceOnly.rawValue)
    }
}
