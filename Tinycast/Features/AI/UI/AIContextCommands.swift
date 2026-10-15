import Foundation

extension AIContextCoordinator {
    // MARK: - @ commands

    enum ContextToken: Sendable {
        case app(String)
        case tab(String)
        case action(String)
        case integration(String)
        case tool(String)
    }

    /// `@app` and `@tab` address the active app or tab; `@action` and friends name a row.
    func contextToken(in text: String) -> (token: ContextToken, rest: String)? {
        let trimmed = text.drop { $0 == " " }
        guard trimmed.first == "@" else { return nil }
        let after = trimmed.dropFirst()
        for word in
            ["app", "tab", "actions", "action", "integrations", "integration", "tools", "tool"]
        {
            guard after.lowercased().hasPrefix(word) else { continue }
            let tail = after.dropFirst(word.count)
            guard tail.isEmpty || tail.first?.isWhitespace == true else { continue }
            let rest = String(tail.drop { $0.isWhitespace })
            let token: ContextToken =
                switch word {
                case "app": .app(rest)
                case "tab": .tab(rest)
                case "action", "actions": .action(rest)
                case "integration", "integrations": .integration(rest)
                default: .tool(rest)
                }
            return (token, rest)
        }
        return nil
    }

    /// The chip the composer shows while an `@`-context command is typed.
    func addressedContext(in draft: String) -> String? {
        guard
            MCPComposerAddress.parse(draft, slugs: core.mcpCoordinator.slugs).slug == nil,
            let (token, _) = contextToken(in: draft)
        else { return nil }
        switch token {
        case .app: return "@app"
        case .tab: return "@tab"
        case .action: return "@action"
        case .integration: return "@integration"
        case .tool: return "@tool"
        }
    }

    func prepareWithToken(
        _ token: ContextToken, rest: String, in chat: AIChatState,
        snapshot: ContextAppReader.Snapshot?, onStaged: @escaping @MainActor (String) -> Void
    ) {
        switch token {
        case .app:
            attachAppContext(
                to: chat, snapshot: snapshot ?? windowSnapshot, automatic: false,
                onStaged: { onStaged(rest) })
        case .tab:
            if frontTabIsPrivate {
                core.showMessage(ContextBrowser.ReadFailure.restrictedPage.message, tone: .neutral)
                return
            }
            guard let active = activeTab else {
                refreshTabsIfAllowed()
                core.showMessage("There's no browser tab to attach right now.", tone: .neutral)
                return
            }
            attachBrowserTab(to: chat, tab: active, automatic: false, onStaged: { onStaged(rest) })
        case .action(let query):
            if let remainder = prepareActionToken(query, in: chat) { onStaged(remainder) }
        case .integration(let query):
            if let remainder = prepareIntegrationToken(query, in: chat) { onStaged(remainder) }
        case .tool(let query):
            if let remainder = prepareToolToken(query, in: chat) { onStaged(remainder) }
        }
    }

    private func prepareActionToken(_ query: String, in chat: AIChatState) -> String? {
        let candidates = BuiltInQuickAction.allCases.map { QuickAction.builtIn($0) }
            + core.customQuickActions.actions.prefix(8).map { QuickAction.custom($0) }
        guard let choice = ContextPolicy.namedChoice(in: query, names: candidates.map(\.title)),
            let action = candidates.first(where: { $0.title == choice.name })
        else {
            core.showMessage("Name an Action after @action, or pick one from the + menu.", tone: .neutral)
            return nil
        }
        return attachAction(to: chat, action: action) ? choice.remainder : nil
    }

    private func prepareIntegrationToken(_ query: String, in chat: AIChatState) -> String? {
        let servers = core.mcpCoordinator.servers
        let names = servers.map { $0.title.isEmpty ? $0.slug : $0.title } + servers.map(\.slug)
        guard let choice = ContextPolicy.namedChoice(in: query, names: names),
            let server = servers.first(where: { $0.slug == choice.name || $0.title == choice.name })
        else {
            core.showMessage(
                "Name an integration after @integration, or pick one from the + menu.", tone: .neutral)
            return nil
        }
        return attachIntegration(to: chat, server: server) ? choice.remainder : nil
    }

    private func prepareToolToken(_ query: String, in chat: AIChatState) -> String? {
        let tools = chatCoordinator.contextTools(for: chat)
        let names = tools.flatMap { [$0.title, $0.name] }
        guard let choice = ContextPolicy.namedChoice(in: query, names: names),
            let tool = tools.first(where: { $0.name == choice.name || $0.title == choice.name })
        else {
            core.showMessage("Name a tool after @tool, or pick one from the + menu.", tone: .neutral)
            return nil
        }
        return attachTool(to: chat, tool: tool) ? choice.remainder : nil
    }
}
