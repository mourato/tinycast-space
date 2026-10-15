import Combine
import SwiftUI

/// A peer of the AI pane: its results open in Quick AI, and the chat model answers them.
struct QuickActionsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var appSettings
    @Environment(QuickActionSettingsStore.self) private var store
    @Environment(CustomQuickActionStore.self) private var customActions
    @Environment(VisibilityStore.self) private var visibility

    /// Polled like the Permissions pane: the grant lands in System Settings, which sends nothing.
    @State private var isTrusted = Permissions.isAccessibilityTrusted()
    @State private var editingAction: BuiltInQuickAction?
    @State private var customEditing: CustomQuickActionEditRequest?
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: enabledBinding) {
                    SettingsFeatureToggleLabel(
                        anchor: .quickActionsQuickActions, title: "Enable Quick Actions",
                        subtitle: "Act on selected text. Nothing is read until you press a shortcut.")
                }
                if appSettings.quickActionsEnabled, !isTrusted {
                    // Every shortcut fails without it; better said here than found one press later.
                    HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(width: Theme.Size.settingsRowIcon)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Accessibility permission required")
                                .foregroundStyle(.orange)
                            Text("Needed to read your selection.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Spacing.lg)
                        Button("Open System Settings") { Permissions.openAccessibilitySettings() }
                    }
                }
            } header: {
                SettingsSectionHeader(.quickActionsQuickActions)
            }

            Group {
                actionsSection
                languageSection
            }
            .settingsEnabled(appSettings.quickActionsEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.quickActions)
        .onReceive(refreshTimer) { _ in isTrusted = Permissions.isAccessibilityTrusted() }
        .settingsEditorPanel(item: $editingAction) { action in
            InstructionsEditorPanel(
                action: action, instructionOverride: store.settings.instructionOverride(for: action)
            ) { instructionOverride in
                store.settings.setInstructionOverride(instructionOverride, for: action)
            }
        }
        .settingsEditorPanel(item: $customEditing) { request in
            CustomQuickActionEditorPanel(request: request)
        }
        .onAppear {
            core.quickActionCoordinator.loadLanguages()
            core.applyInstalledAILifecycle()
        }
        .onChange(of: appSettings.aiEnabled) { core.applyInstalledAILifecycle() }
    }

    private var actionsSection: some View {
        Section {
            ForEach(BuiltInQuickAction.allCases, content: builtInRow)
            ForEach(customActions.actions) { action in
                SettingsRow(title: action.name, subtitle: nil) {
                    SymbolImage(name: action.symbol, size: Theme.Size.quickActionHeaderIcon)
                        .frame(width: Theme.Size.settingsRowIcon)
                } trailing: {
                    editButton(title: action.name) {
                        customEditing = CustomQuickActionEditRequest(action: action)
                    }
                    AliasField(key: action.entryID, name: action.name)
                    ShortcutRecorder(action: .quickAction(id: action.id), isQuiet: true)
                    resultPicker(title: action.name, selection: previewBinding(action))
                    launcherToggle(title: action.name, entry: AppEntry(action))
                }
            }
            Button {
                customEditing = CustomQuickActionEditRequest(action: nil)
            } label: {
                SettingsRowTitle(.quickActionsActions, "Add Quick Action")
            }
        } header: {
            SettingsSectionHeader(.quickActionsActions)
        } footer: {
            Text(
                appSettings.aiEnabled
                    ? "Quick AI shows each result, where Replace writes it back. Replace only writes "
                        + "the result back as soon as it finishes, without opening Quick AI."
                    : "Turn on AI Chat to use Quick Actions."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func builtInRow(_ action: BuiltInQuickAction) -> some View {
        let entry = CommandCatalog.entry(for: CommandID(action))
        return SettingsRow(title: action.title, subtitle: nil) {
            Image(systemName: action.symbol)
                .frame(width: Theme.Size.settingsRowIcon)
        } trailing: {
            if !action.usesTranslationFramework {
                editButton(title: action.title) { editingAction = action }
            }
            if let entry { AliasField(entry: entry) }
            ShortcutRecorder(action: .command(CommandID(action)), isQuiet: true)
            if action.replacesSelection {
                resultPicker(title: action.title, selection: previewBinding(action))
            }
            if let entry { launcherToggle(title: action.title, entry: entry) }
        }
    }

    private func editButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SymbolImage(name: "pencil", size: Theme.Size.quickActionHeaderIcon)
        }
        .buttonStyle(.plain)
        .help("Edit \(title)")
        .accessibilityLabel("Edit \(title)")
    }

    /// `true` is Quick AI, `false` is Replace only: the same choice on a built-in and a custom action.
    private func resultPicker(title: String, selection: Binding<Bool>) -> some View {
        Picker("", selection: selection) {
            Text("Quick AI").tag(true)
            Text("Replace only").tag(false)
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("What \(title) does with its result")
    }

    private func launcherToggle(title: String, entry: AppEntry) -> some View {
        Toggle("", isOn: launcherBinding(entry))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .launcherVisibilityHelp()
            .accessibilityLabel("Show \(title) in launcher")
    }

    private var languageSection: some View {
        Section {
            Picker(selection: languageBinding) {
                Text("Same as this Mac").tag("")
                ForEach(core.quickActionCoordinator.offeredLanguages, id: \.minimalIdentifier) {
                    Text(TextTranslator.displayName(of: $0)).tag($0.minimalIdentifier)
                }
            } label: {
                SettingsRowTitle(.quickActionsTranslate, "Translate to")
            }
        } header: {
            SettingsSectionHeader(.quickActionsTranslate)
        } footer: {
            Text("Apple's translator, on this Mac. A language downloads on first use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { appSettings.quickActionsEnabled },
            set: { core.quickActionCoordinator.setEnabled($0) })
    }

    private func previewBinding(_ action: BuiltInQuickAction) -> Binding<Bool> {
        Binding(
            get: { !store.settings.replacesOnly(action) },
            set: { store.settings.setReplacesOnly(!$0, for: action) })
    }

    private func previewBinding(_ action: CustomQuickAction) -> Binding<Bool> {
        Binding(
            get: { action.previewsResult },
            set: { core.quickActionCoordinator.setPreviewsResult($0, id: action.id) })
    }

    private func launcherBinding(_ entry: AppEntry) -> Binding<Bool> {
        Binding(
            get: { visibility.isItemVisible(entry) },
            set: { visibility.setItemVisible($0, for: entry) })
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { store.settings.targetLanguage },
            set: { store.settings.targetLanguage = $0 })
    }

    private struct InstructionsEditorPanel: View {
        @Environment(\.settingsEditorDismiss) private var dismiss
        @State private var instructions: String

        let action: BuiltInQuickAction
        let builtIn: String
        let onSave: (String?) -> Void

        init(
            action: BuiltInQuickAction, instructionOverride: String?,
            onSave: @escaping (String?) -> Void
        ) {
            self.action = action
            let builtIn = QuickActionPrompt.instructions(for: action)
            _instructions = State(initialValue: instructionOverride ?? builtIn)
            self.builtIn = builtIn
            self.onSave = onSave
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                SettingsEditorHeader(
                    title: "Customize \(action.title)",
                    subtitle: "Tell Tinycast how you want \(action.title) to handle your selected text."
                )

                TextEditor(text: $instructions)
                    .font(.body)
                    .settingsEditorTextArea(height: Theme.Size.editorTextHeight * 2)

                HStack(spacing: Theme.Spacing.md) {
                    Button("Use Default") { instructions = builtIn }
                        .buttonStyle(.modalAction(.standard, fillsWidth: false))
                        .disabled(instructions == builtIn)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.modalAction(.cancel))
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        onSave(instructions == builtIn ? nil : instructions)
                        dismiss()
                    }
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Theme.Spacing.dialogInset)
            .frame(width: Theme.Size.editorSheetWidth)
            .settingsEditorPanelSurface()
        }
    }
}
