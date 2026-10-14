import AppKit
import SwiftUI

/// Context both chat surfaces share: capture, staging, auto-attach and the pickers that offer it.
@MainActor
@Observable
final class AIContextCoordinator {
    let settings: AppSettings
    unowned let core: AppCore
    unowned let chatCoordinator: AIChatCoordinator

    /// The window surface's root target, taken before the window shows, like the palette's own.
    var windowSnapshot: ContextAppReader.Snapshot?

    /// On-demand tab list; refreshed when a chat opens, read when a picker renders.
    private(set) var tabs: [ContextBrowser.BrowserTab] = []
    @ObservationIgnored private var tabsTask: Task<Void, Never>?
    @ObservationIgnored private var captureTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var captureTickets: [UUID: ContextPolicy.CaptureTicket] = [:]
    @ObservationIgnored private var cancelledOperations: Set<UUID> = []
    /// Auto-staged attachments, so removing one opts that source out until the chat changes.
    @ObservationIgnored private var autoAttachments: [UUID: (chatID: UUID, sourceKey: String)] = [:]
    @ObservationIgnored private var dismissedAutoKeys: [UUID: Set<String>] = [:]
    @ObservationIgnored private var lastAutoKey: [UUID: String] = [:]

    init(settings: AppSettings, chatCoordinator: AIChatCoordinator, core: AppCore) {
        self.settings = settings
        self.chatCoordinator = chatCoordinator
        self.core = core
    }

    var options: ContextPolicy.Options { settings.contextPolicyOptions }

    // MARK: - Entering

    /// Stages automatic context on entering Quick AI from an external app; never on keystrokes.
    func enteredQuickAI(chat: AIChatState, snapshot: ContextAppReader.Snapshot?) {
        refreshTabsIfAllowed()
        let options = options
        guard ContextPolicy.canAutoAttachApp(options: options, aiEnabled: settings.aiEnabled),
            let snapshot
        else {
            autoAttachBrowserIfAllowed(chat: chat)
            return
        }
        attachAppContext(to: chat, snapshot: snapshot, automatic: true)
        autoAttachBrowserIfAllowed(chat: chat)
    }

    /// Stages automatic context on opening the window; the snapshot predates the window.
    func enteredWindow(chat: AIChatState) {
        refreshTabsIfAllowed()
        if let snapshot = windowSnapshot,
            ContextPolicy.canAutoAttachApp(options: options, aiEnabled: settings.aiEnabled)
        {
            attachAppContext(to: chat, snapshot: snapshot, automatic: true)
        }
        autoAttachBrowserIfAllowed(chat: chat)
    }

    private func autoAttachBrowserIfAllowed(chat: AIChatState) {
        guard
            ContextPolicy.canAutoAttachBrowser(options: options, aiEnabled: settings.aiEnabled)
        else { return }
        let ticketChat = chat
        Task { [weak self] in
            await self?.refreshTabsAndAttachActive(chat: ticketChat)
        }
    }

    // MARK: - Manual capture

    func attachAppContext(
        to chat: AIChatState, snapshot: ContextAppReader.Snapshot?, automatic: Bool
    ) {
        let options = options
        guard ContextPolicy.canCaptureApp(options: options, aiEnabled: settings.aiEnabled) else {
            if !automatic { core.showMessage("Turn on app context in Settings → Context.", tone: .neutral) }
            return
        }
        guard let snapshot else {
            if !automatic {
                core.showMessage("Summon Tinycast from an app to quote it.", tone: .neutral)
            }
            return
        }
        if automatic, !shouldAutoStage(chat: chat, sourceKey: snapshot.sourceKey) { return }
        let ticket = ContextPolicy.CaptureTicket(
            operationID: UUID(), chatID: chat.session.id, sourceKey: snapshot.sourceKey)
        beginCapture(ticket: ticket, chat: chat)
        let selectionOnly = options.selectionOnly
        captureTasks[ticket.chatID] = Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) {
                ContextAppReader.read(snapshot, wantsFull: !selectionOnly)
            }.value
            guard let self else { return }
            await self.publishAppRead(
                read, ticket: ticket, chat: chat, snapshot: snapshot, automatic: automatic)
        }
    }

    private func publishAppRead(
        _ read: ContextAppReader.Read, ticket: ContextPolicy.CaptureTicket, chat: AIChatState,
        snapshot: ContextAppReader.Snapshot, automatic: Bool
    ) async {
        guard checkTicket(ticket, chat: chat, source: .apps) else { return }
        let current = options
        guard let body = ContextPolicy.resolveBody(
            selection: read.selection, full: read.value, selectionOnly: current.selectionOnly)
        else {
            if !automatic {
                core.showMessage(
                    read.skippedSecureInput
                        ? "That window is showing secure text, which Tinycast never reads."
                        : "No readable text in \(snapshot.name) — select something first.",
                    tone: .neutral)
            }
            return
        }
        let title =
            read.windowTitle.map { "\(snapshot.name) — \($0)" } ?? snapshot.name
        let payload = ContextPolicy.compose(
            source: .apps, title: title, origin: snapshot.bundleIdentifier ?? snapshot.name,
            body: body, includeOrigin: current.includeOrigin)
        stage(payload, ticket: ticket, chat: chat, automatic: automatic)
    }

    func attachBrowserTab(
        to chat: AIChatState, tab: ContextBrowser.BrowserTab, automatic: Bool
    ) {
        let options = options
        guard ContextPolicy.canCaptureBrowser(options: options, aiEnabled: settings.aiEnabled) else {
            if !automatic {
                core.showMessage("Turn on browser context in Settings → Context.", tone: .neutral)
            }
            return
        }
        if automatic, !shouldAutoStage(chat: chat, sourceKey: tab.sourceKey) { return }
        let ticket = ContextPolicy.CaptureTicket(
            operationID: UUID(), chatID: chat.session.id, sourceKey: tab.sourceKey)
        beginCapture(ticket: ticket, chat: chat)
        captureTasks[ticket.chatID] = Task { [weak self] in
            let result = await ContextBrowserRunner.readTab(
                id: tab.id, windowID: tab.windowID, expectedURL: tab.url)
            guard let self else { return }
            await self.publishTabRead(
                result, ticket: ticket, chat: chat, tab: tab, automatic: automatic)
        }
    }

    private func publishTabRead(
        _ result: Result<ContextBrowser.PageRead, ContextBrowser.ReadFailure>,
        ticket: ContextPolicy.CaptureTicket, chat: AIChatState, tab: ContextBrowser.BrowserTab,
        automatic: Bool
    ) async {
        guard checkTicket(ticket, chat: chat, source: .browserTabs) else { return }
        let current = options
        switch result {
        case .failure(let failure):
            if !automatic || failure == .automationDenied {
                core.showMessage(failure.message, tone: .neutral)
            }
            return
        case .success(let read):
            guard
                let body = ContextPolicy.resolveBody(
                    selection: read.selection, full: read.body,
                    selectionOnly: current.selectionOnly)
            else {
                if !automatic { core.showMessage(ContextBrowser.ReadFailure.empty.message, tone: .neutral) }
                return
            }
            let payload = ContextPolicy.compose(
                source: .browserTabs, title: tab.title.isEmpty ? (tab.host ?? "Browser tab") : tab.title,
                origin: ContextBrowser.sanitizedOrigin(url: read.url),
                body: body, includeOrigin: current.includeOrigin)
            stage(payload, ticket: ticket, chat: chat, automatic: automatic)
        }
    }

    /// Quick Action descriptions ride as context; running one is never on offer here.
    func attachAction(to chat: AIChatState, action: QuickAction) {
        guard
            ContextPolicy.allowsManual(
                source: .actions, options: options, aiEnabled: settings.aiEnabled)
        else {
            core.showMessage("Turn on Actions in Settings → Context → Context Items.", tone: .neutral)
            return
        }
        let text = "Action: \(action.title)\n\n\(QuickActionPrompt.instructions(for: action))"
        guard
            let body = ContextPolicy.resolveBody(
                selection: nil, full: text, selectionOnly: false)
        else { return }
        let payload = ContextPolicy.compose(
            source: .actions, title: action.title, origin: nil, body: body,
            includeOrigin: options.includeOrigin)
        stage(payload, ticket: nil, chat: chat, automatic: false)
    }

    /// Server metadata rides as context; it neither enables the server nor calls anything.
    func attachIntegration(to chat: AIChatState, server: MCPServer) {
        guard settings.aiEnabled, settings.mcpEnabled else {
            core.showMessage("Turn on AI and MCP to quote an integration.", tone: .neutral)
            return
        }
        guard
            ContextPolicy.allowsManual(
                source: .integrations, options: options, aiEnabled: settings.aiEnabled),
            core.mcpCoordinator.server(slug: server.slug) != nil,
            chat.toolScope.allows(server.slug)
        else {
            core.showMessage("That integration isn't available to this chat.", tone: .neutral)
            return
        }
        let text = """
            Integration: \(server.title) (@\(server.slug))
            Transport: \(server.transport.summary)
            Trust: \(server.trust.title)

            Attaching this describes the integration for the model. \
            It does not enable the server or call anything.
            """
        guard
            let body = ContextPolicy.resolveBody(selection: nil, full: text, selectionOnly: false)
        else { return }
        let payload = ContextPolicy.compose(
            source: .integrations, title: server.title.isEmpty ? server.slug : server.title,
            origin: nil, body: body, includeOrigin: options.includeOrigin)
        stage(payload, ticket: nil, chat: chat, automatic: false)
    }

    /// Tool metadata rides as context; the tool itself is never called because it was attached.
    func attachTool(to chat: AIChatState, tool: AITool) {
        guard settings.aiEnabled, settings.mcpEnabled else {
            core.showMessage("Turn on AI and MCP to quote a tool.", tone: .neutral)
            return
        }
        guard ContextPolicy.allowsManual(
            source: .tools, options: options, aiEnabled: settings.aiEnabled)
        else {
            core.showMessage("Turn on Tools in Settings → Context → Context Items.", tone: .neutral)
            return
        }
        guard chatCoordinator.capabilities(for: chat).tools else {
            core.showMessage("This model can't call tools. Switch model to use them.", tone: .neutral)
            return
        }
        if let route = MCPToolName.parse(tool.name), !chat.toolScope.allows(route.slug) {
            core.showMessage("That tool isn't available to this chat.", tone: .neutral)
            return
        }
        let text = """
            Tool: \(tool.title) (from \(tool.origin))
            Name: \(tool.name)

            \(tool.description.isEmpty ? "No description." : tool.description)

            Attaching this describes the tool for the model. \
            It does not call the tool or enable anything.
            """
        guard
            let body = ContextPolicy.resolveBody(selection: nil, full: text, selectionOnly: false)
        else { return }
        let payload = ContextPolicy.compose(
            source: .tools, title: tool.title, origin: nil, body: body,
            includeOrigin: options.includeOrigin)
        stage(payload, ticket: nil, chat: chat, automatic: false)
    }

    // MARK: - Capture ownership

    private func beginCapture(ticket: ContextPolicy.CaptureTicket, chat: AIChatState) {
        if let previous = captureTasks[ticket.chatID] {
            if let running = captureTickets[ticket.chatID] {
                cancelledOperations.insert(running.operationID)
            }
            previous.cancel()
        }
        captureTickets[ticket.chatID] = ticket
    }

    /// Late reads publish only while their ticket is still the destination's own.
    private func checkTicket(
        _ ticket: ContextPolicy.CaptureTicket, chat: AIChatState, source: ContextSource
    ) -> Bool {
        let current = options
        let captureAllowed =
            switch source {
            case .apps: ContextPolicy.canCaptureApp(options: current, aiEnabled: settings.aiEnabled)
            case .browserTabs: ContextPolicy.canCaptureBrowser(
                    options: current, aiEnabled: settings.aiEnabled)
            case .actions, .integrations, .tools: settings.aiEnabled
            case .memoryGroups, .variables: false
            }
        return ContextPolicy.shouldPublish(
            ticket: ticket, latest: captureTickets[chat.session.id] ?? ticket,
            latestCancelled: cancelledOperations.contains(ticket.operationID)
                || Task.isCancelled,
            captureAllowed: captureAllowed)
    }

    private func stage(
        _ payload: ContextPolicy.Payload, ticket: ContextPolicy.CaptureTicket?,
        chat: AIChatState, automatic: Bool
    ) {
        let attachment = ChatAttachment(
            payload: .document(payload.document), name: payload.name, preview: nil)
        if let refusal = chat.attach(attachment) {
            core.showMessage(refusal.message, tone: .neutral)
            return
        }
        if automatic, let ticket {
            autoAttachments[attachment.id] = (chat.session.id, ticket.sourceKey)
            lastAutoKey[chat.session.id] = ticket.sourceKey
        }
        if payload.isPartial {
            core.showMessage(
                "Attached a shortened quote — the full text didn't fit.", tone: .neutral)
        }
    }

    private func shouldAutoStage(chat: AIChatState, sourceKey: String) -> Bool {
        guard chat.pendingAttachments.isEmpty else { return false }
        guard dismissedAutoKeys[chat.session.id]?.contains(sourceKey) != true else { return false }
        return lastAutoKey[chat.session.id] != sourceKey
    }

    /// Turning capture off cancels in-flight reads; staged quotes stay, owned by the reader.
    func cancelAllCaptures() {
        for task in captureTasks.values { task.cancel() }
        for ticket in captureTickets.values { cancelledOperations.insert(ticket.operationID) }
        captureTasks = [:]
    }

    /// A removed auto quote opts its source out until the chat turns over.
    func noteRemoved(_ id: UUID) {
        guard let entry = autoAttachments.removeValue(forKey: id) else { return }
        dismissedAutoKeys[entry.chatID, default: []].insert(entry.sourceKey)
    }

    func noteCleared(in chat: AIChatState) {
        for (id, entry) in autoAttachments where entry.chatID == chat.session.id {
            dismissedAutoKeys[entry.chatID, default: []].insert(entry.sourceKey)
            autoAttachments.removeValue(forKey: id)
        }
    }

    func forget(chatID: UUID) {
        captureTasks[chatID]?.cancel()
        captureTasks[chatID] = nil
        captureTickets[chatID] = nil
        dismissedAutoKeys[chatID] = nil
        lastAutoKey[chatID] = nil
        for (id, entry) in autoAttachments where entry.chatID == chatID {
            autoAttachments.removeValue(forKey: id)
        }
    }

    // MARK: - Tabs

    func refreshTabsIfAllowed() {
        guard
            ContextPolicy.canCaptureBrowser(options: options, aiEnabled: settings.aiEnabled)
        else { return }
        tabsTask?.cancel()
        tabsTask = Task { [weak self] in
            let result = await ContextBrowserRunner.listTabs()
            guard let self, !Task.isCancelled else { return }
            if case .success(let tabs) = result { self.tabs = tabs }
        }
    }

    private func refreshTabsAndAttachActive(chat: AIChatState) async {
        if tabs.isEmpty {
            if case .success(let listed) = await ContextBrowserRunner.listTabs() {
                guard !Task.isCancelled else { return }
                self.tabs = listed
            }
        }
        guard let active = ContextBrowser.activeTab(in: tabs) else { return }
        attachBrowserTab(to: chat, tab: active, automatic: true)
    }

    var activeTab: ContextBrowser.BrowserTab? { ContextBrowser.activeTab(in: tabs) }

    // MARK: - @ commands

    enum ContextToken: Sendable {
        case app(String)
        case tab(String)
    }

    /// `@app` and `@tab` address the active app or tab; anything else stays plain text.
    func contextToken(in text: String) -> (token: ContextToken, rest: String)? {
        let trimmed = text.drop { $0 == " " }
        guard trimmed.first == "@" else { return nil }
        let after = trimmed.dropFirst()
        for word in ["app", "tab"] {
            guard after.lowercased().hasPrefix(word) else { continue }
            let tail = after.dropFirst(word.count)
            guard tail.isEmpty || tail.first?.isWhitespace == true else { continue }
            let rest = String(tail.drop { $0.isWhitespace })
            let token = word == "app" ? ContextToken.app(rest) : ContextToken.tab(rest)
            return (token, rest)
        }
        return nil
    }

    /// The chip the composer shows while an `@app` or `@tab` command is typed.
    func addressedContext(in draft: String) -> String? {
        guard
            MCPComposerAddress.parse(draft, slugs: core.mcpCoordinator.slugs).slug == nil,
            let (token, _) = contextToken(in: draft)
        else { return nil }
        switch token {
        case .app: return "@app"
        case .tab: return "@tab"
        }
    }

    /// An explicit gesture, so the capture it names stages and then sends as one turn.
    func sendWithToken(
        _ token: ContextToken, rest: String, in chat: AIChatState,
        snapshot: ContextAppReader.Snapshot?
    ) -> Bool {
        switch token {
        case .app:
            attachAppContext(to: chat, snapshot: snapshot ?? windowSnapshot, automatic: false)
        case .tab:
            guard let active = activeTab else {
                refreshTabsIfAllowed()
                core.showMessage("There's no browser tab to attach right now.", tone: .neutral)
                return true
            }
            attachBrowserTab(to: chat, tab: active, automatic: false)
        }
        guard let capture = captureTasks[chat.session.id] else { return true }
        Task {
            await capture.value
            guard !Task.isCancelled else { return }
            chatCoordinator.send(rest, in: chat)
        }
        return true
    }
}
