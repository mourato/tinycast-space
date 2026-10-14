import SwiftUI

/// What Quick AI and AI Chat may quote, and when they may stage it unasked.
struct ContextSettingsView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(AIContextCoordinator.self) private var contextCoordinator

    var body: some View {
        @Bindable var settings = appSettings
        return Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { settings.contextAppEnabled },
                        set: { contextCoordinator.setAppEnabled($0) })
                ) {
                    SettingsFeatureToggleLabel(
                        anchor: .contextApplication, title: "Enable app context",
                        subtitle: "Let chats quote the front app's selected or visible text.")
                }
                Toggle(isOn: $settings.contextAutoAttachApp) {
                    SettingsRowTitle(.contextApplication, "Automatically attach active app")
                    Text("Stage the front app's text whenever a chat opens.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.contextAppEnabled)
                if settings.contextAppEnabled, !Permissions.isAccessibilityTrusted() {
                    LabeledContent {
                        Button("Grant Access…") { Permissions.openAccessibilitySettings() }
                    } label: {
                        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .frame(width: SettingsListMetrics.iconSize)
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text("App quoting needs Accessibility access")
                                    .foregroundStyle(.orange)
                                Text("Without the grant there is nothing to attach.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                SettingsSectionHeader(.contextApplication)
            } footer: {
                Text(
                    "Reads with Accessibility, and only after you switch it on here. "
                        + "Without the grant there is nothing to attach.")
            }

            Section {
                Toggle(isOn: $settings.contextBrowserEnabled) {
                    SettingsFeatureToggleLabel(
                        anchor: .contextBrowser, title: "Enable browser context",
                        subtitle: "Let chats quote the Helium tab you attach.")
                }
                Toggle(isOn: $settings.contextAutoAttachBrowser) {
                    SettingsRowTitle(.contextBrowser, "Automatically attach active tab")
                    Text("Stage the active Helium tab whenever a chat opens.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .disabled(!settings.contextBrowserEnabled)
            } header: {
                SettingsSectionHeader(.contextBrowser)
            } footer: {
                Text(
                    "Reads with Automation; the first read asks for Helium. "
                        + "Private windows are never captured.")
            }

            Section {
                Toggle(isOn: $settings.contextSelectionOnly) {
                    SettingsRowTitle(.contextOptions, "Use selected text only")
                    Text("A nonempty selection replaces the whole app or page.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.contextIncludeOrigin) {
                    SettingsRowTitle(.contextOptions, "Include active app or tab")
                    Text("Names the app or tab a quote came from. Separate from auto-attach.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.contextPrioritizeActiveApp) {
                    SettingsRowTitle(.contextOptions, "Prioritize active app")
                    Text("Lists the front app or tab first in the context pickers.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                SettingsSectionHeader(.contextOptions)
            }

            Section {
                contextSourceRow(
                    enabled: $settings.contextSourceBrowserTabsEnabled,
                    priority: $settings.contextPriorityBrowserTabs, source: .browserTabs,
                    subtitle: "Helium tabs, read when you attach one."
                ) {
                    SettingsRowTitle(.contextItems, "Browser tabs")
                }
                contextSourceRow(
                    enabled: $settings.contextSourceAppsEnabled,
                    priority: $settings.contextPriorityApps, source: .apps,
                    subtitle: "Running apps, quoted from their focused window."
                ) {
                    SettingsRowTitle(.contextItems, "Apps")
                }
                contextSourceRow(
                    enabled: $settings.contextSourceActionsEnabled,
                    priority: $settings.contextPriorityActions, source: .actions,
                    subtitle: "Quick Action prompts, attached as text, never run."
                ) {
                    SettingsRowTitle(.contextItems, "Actions")
                }
                contextSourceRow(
                    enabled: $settings.contextSourceIntegrationsEnabled,
                    priority: $settings.contextPriorityIntegrations, source: .integrations,
                    subtitle: "MCP server details, attached as text, never called."
                ) {
                    SettingsRowTitle(.contextItems, "Integrations")
                }
                contextSourceRow(
                    enabled: $settings.contextSourceToolsEnabled,
                    priority: $settings.contextPriorityTools, source: .tools,
                    subtitle: "MCP tool details, attached as text, never called."
                ) {
                    SettingsRowTitle(.contextItems, "Tools")
                }
                Toggle(isOn: .constant(false)) {
                    SettingsRowTitle(.contextItems, "Memory groups")
                    Text(ContextSource.memoryGroups.unavailableReason ?? "Not available.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .disabled(true)
                Toggle(isOn: .constant(false)) {
                    SettingsRowTitle(.contextItems, "Variables")
                    Text(ContextSource.variables.unavailableReason ?? "Not available.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .disabled(true)
            } header: {
                SettingsSectionHeader(.contextItems)
            } footer: {
                Text(
                    "Priority orders the pickers. A switched-off source hides everywhere. "
                        + "Quotes go out with your next message to the selected model, "
                        + "first as chips you can remove.")
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.context)
        .settingsEnabled(appSettings.aiEnabled)
    }

    private func contextSourceRow<Label: View>(
        enabled: Binding<Bool>, priority: Binding<Double>, source: ContextSource, subtitle: String,
        @ViewBuilder label: () -> Label
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Toggle(isOn: enabled) {
                label()
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Priority")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { priority.wrappedValue },
                        set: {
                            priority.wrappedValue = ContextSource.normalized(
                                priority: $0, for: source)
                        }),
                    in: ContextSource.priorityRange, step: 0.05
                )
                .disabled(!enabled.wrappedValue)
                Text(priority.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
