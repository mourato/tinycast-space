import AppKit

/// One row in either composer's context picker; picking it stages text, never runs anything.
enum AIContextPickerAction: Sendable {
    case activeApp
    case app(pid: pid_t, name: String)
    case activeTab
    case tab(ContextBrowser.BrowserTab)
    case action(QuickAction)
    case integration(MCPServer)
    case tool(AITool)
}

/// What the pickers render: ordered sections of staged-as-text options, plus honest buckets.
struct AIContextPickerData {
    struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let action: AIContextPickerAction?
        /// Set when the row only explains why it cannot be picked.
        let disabledReason: String?
    }

    struct Section: Identifiable {
        let source: ContextSource
        var id: String { source.id }
        let items: [Item]
    }

    let sections: [Section]
}

extension AIContextCoordinator {
    /// The picker's rows for one chat: enabled sources in priority order, then the honest gaps.
    func pickerData(for chat: AIChatState, snapshot: ContextAppReader.Snapshot?) -> AIContextPickerData
    {
        let options = options
        let activeSource: ContextSource? =
            snapshot?.isBrowser == true ? .browserTabs : (snapshot != nil ? .apps : nil)
        var sections = ContextPolicy.orderedSources(options: options, activeSource: activeSource)
            .map { section(for: $0, chat: chat, snapshot: snapshot) }
        for source in ContextSource.allCases where !source.isAvailable {
            sections.append(
                AIContextPickerData.Section(
                    source: source,
                    items: [
                        AIContextPickerData.Item(
                            id: "\(source.rawValue)-unavailable", title: source.title,
                            subtitle: source.unavailableReason ?? "Not available.", action: nil,
                            disabledReason: source.unavailableReason)
                    ]))
        }
        return AIContextPickerData(sections: sections)
    }

    func perform(
        _ action: AIContextPickerAction, in chat: AIChatState,
        snapshot: ContextAppReader.Snapshot?
    ) {
        guard settings.aiEnabled else { return }
        switch action {
        case .activeApp:
            attachAppContext(to: chat, snapshot: snapshot ?? windowSnapshot, automatic: false)
        case .app(let pid, let name):
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                core.showMessage("\(name) is no longer running.", tone: .neutral)
                return
            }
            attachAppContext(
                to: chat, snapshot: ContextAppReader.snapshot(of: app), automatic: false)
        case .activeTab:
            if frontTabIsPrivate {
                core.showMessage(
                    ContextBrowser.ReadFailure.restrictedPage.message, tone: .neutral)
                return
            }
            guard let active = activeTab else {
                refreshTabsIfAllowed()
                core.showMessage("There's no browser tab to attach right now.", tone: .neutral)
                return
            }
            attachBrowserTab(to: chat, tab: active, automatic: false)
        case .tab(let tab):
            attachBrowserTab(to: chat, tab: tab, automatic: false)
        case .action(let action):
            attachAction(to: chat, action: action)
        case .integration(let server):
            attachIntegration(to: chat, server: server)
        case .tool(let tool):
            attachTool(to: chat, tool: tool)
        }
    }

    /// Known running external apps, named; the picker caps how many it shows.
    var runningContextApps: [(pid: pid_t, bundleID: String, name: String)] {
        let browsers = ContextAppReader.browserBundleURLs
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != NSRunningApplication.current.processIdentifier,
                let bundleID = app.bundleIdentifier, !bundleID.hasPrefix("com.tinycast.app"),
                app.activationPolicy == .regular || app.activationPolicy == .accessory,
                !app.isTerminated, !ContextBrowser.isSupported(bundleID: bundleID),
                app.bundleURL.map({ !browsers.contains($0.standardizedFileURL) }) ?? false
            else { return nil }
            return (app.processIdentifier, bundleID, app.localizedName ?? bundleID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func section(
        for source: ContextSource, chat: AIChatState, snapshot: ContextAppReader.Snapshot?
    ) -> AIContextPickerData.Section {
        switch source {
        case .apps: return appsSection(snapshot: snapshot)
        case .browserTabs: return tabsSection()
        case .actions: return actionsSection()
        case .integrations: return integrationsSection(chat: chat)
        case .tools: return toolsSection(chat: chat)
        case .memoryGroups, .variables:
            return AIContextPickerData.Section(source: source, items: [])
        }
    }

    private func appsSection(snapshot: ContextAppReader.Snapshot?) -> AIContextPickerData.Section {
        let canCapture = ContextPolicy.canCaptureApp(options: options, aiEnabled: settings.aiEnabled)
        let reason = canCapture ? nil : "Turn on app context in Settings → Context."
        var items = [
            AIContextPickerData.Item(
                id: "apps-active", title: "Attach Active App",
                subtitle: snapshot.map { appSubtitle($0) } ?? "No app in front",
                action: snapshot == nil ? nil : .activeApp,
                disabledReason: snapshot == nil ? "Summon Tinycast from an app to quote it."
                    : (snapshot?.isBrowser == true ? "Use Browser tabs for browser context." : reason))
        ]
        for app in runningContextApps.prefix(12) {
            items.append(
                AIContextPickerData.Item(
                    id: "apps-\(app.pid)", title: app.name, subtitle: app.bundleID,
                    action: .app(pid: app.pid, name: app.name), disabledReason: reason))
        }
        return AIContextPickerData.Section(source: .apps, items: items)
    }

    private func appSubtitle(_ snapshot: ContextAppReader.Snapshot) -> String {
        snapshot.bundleIdentifier ?? "PID \(snapshot.processIdentifier)"
    }

    private func tabsSection() -> AIContextPickerData.Section {
        let canCapture = ContextPolicy.canCaptureBrowser(
            options: options, aiEnabled: settings.aiEnabled)
        let reason = canCapture ? nil : "Turn on browser context in Settings → Context."
        var items = [
            AIContextPickerData.Item(
                id: "tabs-active", title: "Attach Active Tab",
                subtitle: activeTab.map { tabSubtitle($0) } ?? "No tab listed",
                action: activeTab == nil ? nil : .activeTab,
                disabledReason: activeTab == nil ? "Open a supported browser, then pick again." : reason)
        ]
        for tab in tabs.prefix(10) {
            items.append(
                AIContextPickerData.Item(
                    id: "tabs-\(tab.sourceKey)", title: tab.title.isEmpty ? (tab.host ?? "Untitled") : tab.title,
                    subtitle: tabSubtitle(tab), action: .tab(tab), disabledReason: reason))
        }
        return AIContextPickerData.Section(source: .browserTabs, items: items)
    }

    private func tabSubtitle(_ tab: ContextBrowser.BrowserTab) -> String {
        tab.host ?? tab.url
    }

    private func actionsSection() -> AIContextPickerData.Section {
        let allowed = ContextPolicy.allowsManual(
            source: .actions, options: options, aiEnabled: settings.aiEnabled)
        let reason = allowed ? nil : "Turn on Actions in Settings → Context → Context Items."
        var items = BuiltInQuickAction.allCases.map { builtIn in
            AIContextPickerData.Item(
                id: "actions-\(builtIn.rawValue)", title: builtIn.title,
                subtitle: "Quick Action prompt", action: .action(.builtIn(builtIn)),
                disabledReason: reason)
        }
        for custom in core.customQuickActions.actions.prefix(8) {
            items.append(
                AIContextPickerData.Item(
                    id: "actions-\(custom.entryID)", title: custom.name,
                    subtitle: "Custom Quick Action", action: .action(.custom(custom)),
                    disabledReason: reason))
        }
        return AIContextPickerData.Section(source: .actions, items: items)
    }

    private func integrationsSection(chat: AIChatState) -> AIContextPickerData.Section {
        let servers = core.mcpCoordinator.servers
        let items = servers.map { server -> AIContextPickerData.Item in
            let reason: String?
            if !settings.mcpEnabled || !settings.aiEnabled {
                reason = "Turn on AI and MCP to quote an integration."
            } else if !chat.toolScope.allows(server.slug) {
                reason = "Off for this chat."
            } else if !ContextPolicy.allowsManual(
                source: .integrations, options: options, aiEnabled: settings.aiEnabled)
            {
                reason = "Turn on Integrations in Settings → Context → Context Items."
            } else {
                reason = nil
            }
            return AIContextPickerData.Item(
                id: "integrations-\(server.slug)",
                title: server.title.isEmpty ? server.slug : server.title,
                subtitle: "@\(server.slug)", action: .integration(server), disabledReason: reason)
        }
        if items.isEmpty {
            return AIContextPickerData.Section(
                source: .integrations,
                items: [
                    AIContextPickerData.Item(
                        id: "integrations-empty", title: "No MCP servers connected",
                        subtitle: "Add one in Settings → AI.", action: nil,
                        disabledReason: "Add an MCP server in Settings → AI.")
                ])
        }
        return AIContextPickerData.Section(source: .integrations, items: items)
    }

    private func toolsSection(chat: AIChatState) -> AIContextPickerData.Section {
        let takesTools = chatCoordinator.capabilities(for: chat).tools
        let items = chatCoordinator.contextTools(for: chat).prefix(15).map { tool in
            AIContextPickerData.Item(
                id: "tools-\(tool.name)", title: tool.title, subtitle: tool.origin,
                action: .tool(tool),
                disabledReason: takesTools
                    ? nil : "This model can't call tools. Switch model to use them.")
        }
        if items.isEmpty {
            return AIContextPickerData.Section(
                source: .tools,
                items: [
                    AIContextPickerData.Item(
                        id: "tools-empty", title: "No tools in reach",
                        subtitle: takesTools ? "Connect an MCP server." : "Not with this model.",
                        action: nil,
                        disabledReason: takesTools
                            ? "Connect an MCP server in Settings → AI."
                            : "This model can't call tools. Switch model to use them.")
                ])
        }
        return AIContextPickerData.Section(source: .tools, items: Array(items))
    }
}
