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

    /// One capture slot per destination and source, so app and browser autos never cancel each other.
    struct CaptureSlot: Hashable, Sendable {
        let chatID: UUID
        let source: ContextSource
    }

    /// On-demand tab list; refreshed when a chat opens, read when a picker renders.
    private(set) var tabs: [ContextBrowser.BrowserTab] = []
    /// True when the front Helium window reported private; auto-attach refuses, never swaps.
    private(set) var frontTabIsPrivate = false
    @ObservationIgnored private var tabsTask: Task<Void, Never>?
    @ObservationIgnored private var captureTasks: [CaptureSlot: Task<Void, Never>] = [:]
    @ObservationIgnored private var captureTickets: [CaptureSlot: ContextPolicy.CaptureTicket] = [:]
    @ObservationIgnored private var cancelledOperations: Set<UUID> = []
    @ObservationIgnored private var browserAutoTasks: [UUID: Task<Void, Never>] = [:]
    /// Every staged context attachment, so disabling a source drops its quotes, never files.
    @ObservationIgnored private var contextAttachments: [UUID: (chatID: UUID, source: ContextSource)] = [:]
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

    // MARK: - Enabling

    /// Enabling app context is also Accessibility consent, so it confirms first like snippets.
    func setAppEnabled(_ enabled: Bool) {
        guard enabled != settings.contextAppEnabled else { return }
        if !enabled {
            settings.contextAppEnabled = false
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: "Enable app context?",
                    message:
                        "Chats will be able to quote the front app's text with Accessibility. "
                        + "Quoting stays off until you switch it on here, and every quote stages for review.",
                    symbol: "app.window", confirmTitle: "Continue", tone: .neutral,
                    confirmRole: .standard)
            else { return }
            settings.contextAppEnabled = true
            Permissions.ensureAccessibility()
        }
    }

    // MARK: - Entering

    /// Stages automatic context on entering Quick AI from an external app; never on keystrokes.
    func enteredQuickAI(chat: AIChatState, snapshot: ContextAppReader.Snapshot?) {
        refreshTabsIfAllowed()
        let options = options
        guard ContextPolicy.canAutoAttachApp(options: options, aiEnabled: settings.aiEnabled),
            let snapshot
        else {
            autoAttachBrowserIfAllowed(chat: chat, snapshot: snapshot)
            return
        }
        attachAppContext(to: chat, snapshot: snapshot, automatic: true)
        autoAttachBrowserIfAllowed(chat: chat, snapshot: snapshot)
    }

    /// Stages automatic context on opening the window; the snapshot predates the window.
    func enteredWindow(chat: AIChatState) {
        refreshTabsIfAllowed()
        if let snapshot = windowSnapshot,
            ContextPolicy.canAutoAttachApp(options: options, aiEnabled: settings.aiEnabled)
        {
            attachAppContext(to: chat, snapshot: snapshot, automatic: true)
        }
        autoAttachBrowserIfAllowed(chat: chat, snapshot: windowSnapshot)
    }

    /// True when entering chat would stage something unasked; Quick AI's ask reads it first.
    func autoApplies(snapshot: ContextAppReader.Snapshot?) -> Bool {
        guard settings.aiEnabled else { return false }
        if ContextPolicy.canAutoAttachApp(options: options, aiEnabled: settings.aiEnabled),
            snapshot != nil
        {
            return true
        }
        return browserAutoApplies(snapshot: snapshot)
    }

    /// Browser auto reads Helium's own tab, so it applies only when summoned from Helium.
    private func browserAutoApplies(snapshot: ContextAppReader.Snapshot?) -> Bool {
        guard
            ContextPolicy.canAutoAttachBrowser(options: options, aiEnabled: settings.aiEnabled)
        else { return false }
        return snapshot?.bundleIdentifier == ContextBrowser.heliumBundleID
    }

    private func autoAttachBrowserIfAllowed(
        chat: AIChatState, snapshot: ContextAppReader.Snapshot?
    ) {
        guard browserAutoApplies(snapshot: snapshot) else { return }
        browserAutoTasks[chat.session.id]?.cancel()
        let ticketChat = chat
        browserAutoTasks[chat.session.id] = Task { [weak self] in
            await self?.refreshTabsAndAttachActive(chat: ticketChat)
            guard let self else { return }
            if !Task.isCancelled { self.browserAutoTasks[ticketChat.session.id] = nil }
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
            operationID: UUID(), chatID: chat.session.id, sourceKey: snapshot.sourceKey,
            generation: chat.stagingGeneration, source: .apps)
        beginCapture(ticket: ticket, chat: chat)
        captureTasks[CaptureSlot(chatID: ticket.chatID, source: .apps)] = Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) {
                ContextAppReader.read(snapshot)
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
        defer { retire(ticket: ticket) }
        guard checkTicket(ticket, chat: chat, source: .apps) else { return }
        if read.accessDenied {
            core.showMessage(
                "Tinycast needs Accessibility access to quote apps. "
                    + "Grant it in System Settings → Privacy & Security → Accessibility.",
                tone: .neutral)
            return
        }
        if read.windowChanged {
            if !automatic {
                core.showMessage(
                    "That window moved while reading — try again.", tone: .neutral)
            }
            return
        }
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
            body: body, includeOrigin: current.includeOrigin,
            upstreamTruncated: read.isTruncated)
        stage(payload, ticket: ticket, chat: chat, automatic: automatic, source: .apps)
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
            operationID: UUID(), chatID: chat.session.id, sourceKey: tab.sourceKey,
            generation: chat.stagingGeneration, source: .browserTabs)
        beginCapture(ticket: ticket, chat: chat)
        let slot = CaptureSlot(chatID: ticket.chatID, source: .browserTabs)
        captureTasks[slot] = Task { [weak self] in
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
        defer { retire(ticket: ticket) }
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
                body: body, includeOrigin: current.includeOrigin,
                upstreamTruncated: read.isTruncated)
            stage(payload, ticket: ticket, chat: chat, automatic: automatic, source: .browserTabs)
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
        stage(payload, ticket: nil, chat: chat, automatic: false, source: .actions)
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
        stage(payload, ticket: nil, chat: chat, automatic: false, source: .integrations)
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
        stage(payload, ticket: nil, chat: chat, automatic: false, source: .tools)
    }

    // MARK: - Capture ownership

    private func beginCapture(ticket: ContextPolicy.CaptureTicket, chat: AIChatState) {
        let slot = CaptureSlot(chatID: ticket.chatID, source: ticket.source)
        if let previous = captureTasks[slot] {
            if let running = captureTickets[slot] {
                cancelledOperations.insert(running.operationID)
            }
            previous.cancel()
        }
        captureTickets[slot] = ticket
    }

    /// Late reads publish only while their ticket is still the slot's own; no fallback ticket.
    private func checkTicket(
        _ ticket: ContextPolicy.CaptureTicket, chat: AIChatState, source: ContextSource
    ) -> Bool {
        guard ticket.chatID == chat.session.id, ticket.source == source else { return false }
        let slot = CaptureSlot(chatID: ticket.chatID, source: source)
        guard let latest = captureTickets[slot], latest == ticket else { return false }
        let current = options
        let captureAllowed: Bool =
            switch source {
            case .apps: ContextPolicy.canCaptureApp(options: current, aiEnabled: settings.aiEnabled)
            case .browserTabs: ContextPolicy.canCaptureBrowser(
                    options: current, aiEnabled: settings.aiEnabled)
            case .actions, .integrations, .tools: settings.aiEnabled
            case .memoryGroups, .variables: false
            }
        return ContextPolicy.shouldPublish(
            ticket: ticket, latest: latest,
            latestCancelled: cancelledOperations.contains(ticket.operationID)
                || Task.isCancelled,
            captureAllowed: captureAllowed, currentGeneration: chat.stagingGeneration)
    }

    /// A finished capture frees its slot and its cancellation marker, so neither grows forever.
    private func retire(ticket: ContextPolicy.CaptureTicket) {
        let slot = CaptureSlot(chatID: ticket.chatID, source: ticket.source)
        if captureTickets[slot] == ticket { captureTickets[slot] = nil }
        if captureTasks[slot]?.isCancelled == true { captureTasks[slot] = nil }
        cancelledOperations.remove(ticket.operationID)
    }

    private func stage(
        _ payload: ContextPolicy.Payload, ticket: ContextPolicy.CaptureTicket?,
        chat: AIChatState, automatic: Bool, source: ContextSource
    ) {
        let attachment = ChatAttachment(
            payload: .document(payload.document), name: payload.name, preview: nil)
        if let refusal = chat.attach(attachment) {
            core.showMessage(refusal.message, tone: .neutral)
            return
        }
        contextAttachments[attachment.id] = (chat.session.id, source)
        if automatic, let ticket {
            autoAttachments[attachment.id] = (chat.session.id, ticket.sourceKey)
            lastAutoKey[chat.session.id] = ticket.sourceKey
        }
        if payload.isPartial {
            core.showMessage(
                "Attached a shortened quote — the full text didn't fit.", tone: .neutral)
        }
    }

    /// Autos coexist: a second source stages while only context is pending, never over user files.
    private func shouldAutoStage(chat: AIChatState, sourceKey: String) -> Bool {
        let onlyContext = chat.pendingAttachments.allSatisfy { contextAttachments[$0.id] != nil }
        guard onlyContext else { return false }
        guard dismissedAutoKeys[chat.session.id]?.contains(sourceKey) != true else { return false }
        return lastAutoKey[chat.session.id] != sourceKey
    }

    /// Turning capture off cancels in-flight reads and drops their staged quotes, never files.
    func cancelAllCaptures() {
        for task in captureTasks.values { task.cancel() }
        for task in browserAutoTasks.values { task.cancel() }
        tabsTask?.cancel()
        for ticket in captureTickets.values { cancelledOperations.insert(ticket.operationID) }
        captureTasks = [:]
        captureTickets = [:]
        browserAutoTasks = [:]
    }

    /// A master or source switch re-projects: cancel what's no longer allowed, drop its quotes.
    func optionsDidChange() {
        let current = options
        let appAllowed = ContextPolicy.canCaptureApp(
            options: current, aiEnabled: settings.aiEnabled)
        let browserAllowed = ContextPolicy.canCaptureBrowser(
            options: current, aiEnabled: settings.aiEnabled)
        if !appAllowed { cancelCaptures(source: .apps) }
        if !browserAllowed {
            cancelCaptures(source: .browserTabs)
            browserAutoTasks.values.forEach { $0.cancel() }
            browserAutoTasks = [:]
            tabsTask?.cancel()
        }
        if !settings.aiEnabled { cancelAllCaptures() }
        dropDisallowedContext()
    }

    private func cancelCaptures(source: ContextSource) {
        for (slot, task) in captureTasks where slot.source == source {
            task.cancel()
            if let running = captureTickets[slot] {
                cancelledOperations.insert(running.operationID)
            }
            captureTasks[slot] = nil
            captureTickets[slot] = nil
        }
    }

    /// Staged quotes whose source is now off leave the composer; user files and text stay.
    private func dropDisallowedContext() {
        for chat in chatCoordinator.chats.live {
            for attachment in chat.pendingAttachments {
                guard let entry = contextAttachments[attachment.id] else { continue }
                guard
                    ContextPolicy.allowsManual(
                        source: entry.source, options: options, aiEnabled: settings.aiEnabled)
                else {
                    chat.removeAttachment(attachment.id)
                    contextAttachments[attachment.id] = nil
                    if let auto = autoAttachments.removeValue(forKey: attachment.id) {
                        dismissedAutoKeys[auto.chatID, default: []].insert(auto.sourceKey)
                    }
                    continue
                }
                if (entry.source == .apps
                    && !ContextPolicy.canCaptureApp(
                        options: options, aiEnabled: settings.aiEnabled))
                    || (entry.source == .browserTabs
                        && !ContextPolicy.canCaptureBrowser(
                            options: options, aiEnabled: settings.aiEnabled))
                {
                    chat.removeAttachment(attachment.id)
                    contextAttachments[attachment.id] = nil
                    if let auto = autoAttachments.removeValue(forKey: attachment.id) {
                        dismissedAutoKeys[auto.chatID, default: []].insert(auto.sourceKey)
                    }
                }
            }
        }
    }

    /// A removed auto quote opts its source out until the chat turns over.
    func noteRemoved(_ id: UUID) {
        contextAttachments[id] = nil
        guard let entry = autoAttachments.removeValue(forKey: id) else { return }
        dismissedAutoKeys[entry.chatID, default: []].insert(entry.sourceKey)
    }

    func noteCleared(in chat: AIChatState) {
        contextAttachments = contextAttachments.filter { $0.value.chatID != chat.session.id }
        for (id, entry) in autoAttachments where entry.chatID == chat.session.id {
            dismissedAutoKeys[entry.chatID, default: []].insert(entry.sourceKey)
            autoAttachments.removeValue(forKey: id)
        }
    }

    func forget(chatID: UUID) {
        for source in [ContextSource.apps, ContextSource.browserTabs] as [ContextSource] {
            let slot = CaptureSlot(chatID: chatID, source: source)
            captureTasks[slot]?.cancel()
            captureTasks[slot] = nil
            captureTickets[slot] = nil
        }
        browserAutoTasks[chatID]?.cancel()
        browserAutoTasks[chatID] = nil
        dismissedAutoKeys[chatID] = nil
        lastAutoKey[chatID] = nil
        for (id, entry) in contextAttachments where entry.chatID == chatID {
            contextAttachments.removeValue(forKey: id)
        }
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
            if case .success(let listed) = result {
                self.tabs = listed.tabs
                self.frontTabIsPrivate = listed.frontIsPrivate
            }
        }
    }

    /// Auto-attach reads a fresh list every trigger: cached tabs may point at a moved page.
    private func refreshTabsAndAttachActive(chat: AIChatState) async {
        guard ContextBrowserRunner.isHeliumRunning() else { return }
        let listed: ContextBrowserRunner.TabList
        switch await ContextBrowserRunner.listTabs() {
        case .failure(let failure):
            if failure == .automationDenied { core.showMessage(failure.message, tone: .neutral) }
            return
        case .success(let fresh): listed = fresh
        }
        guard !Task.isCancelled else { return }
        self.tabs = listed.tabs
        self.frontTabIsPrivate = listed.frontIsPrivate
        guard !listed.frontIsPrivate else { return }
        guard let active = ContextBrowser.activeTab(in: listed.tabs) else { return }
        attachBrowserTab(to: chat, tab: active, automatic: true)
    }

    var activeTab: ContextBrowser.BrowserTab? { ContextBrowser.activeTab(in: tabs) }

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

    /// An explicit gesture, so the capture it names stages for review; it never sends by itself.
    func prepareWithToken(
        _ token: ContextToken, rest: String, in chat: AIChatState,
        snapshot: ContextAppReader.Snapshot?
    ) -> String {
        switch token {
        case .app:
            attachAppContext(to: chat, snapshot: snapshot ?? windowSnapshot, automatic: false)
        case .tab:
            if frontTabIsPrivate {
                core.showMessage(
                    ContextBrowser.ReadFailure.restrictedPage.message, tone: .neutral)
                break
            }
            guard let active = activeTab else {
                refreshTabsIfAllowed()
                core.showMessage("There's no browser tab to attach right now.", tone: .neutral)
                break
            }
            attachBrowserTab(to: chat, tab: active, automatic: false)
        case .action(let query):
            prepareActionToken(query, in: chat)
        case .integration(let query):
            prepareIntegrationToken(query, in: chat)
        case .tool(let query):
            prepareToolToken(query, in: chat)
        }
        return rest
    }

    /// The picker's rows by name; an empty or unmatched query names the + menu instead of guessing.
    private func prepareActionToken(_ query: String, in chat: AIChatState) {
        let candidates = BuiltInQuickAction.allCases.map { QuickAction.builtIn($0) }
            + core.customQuickActions.actions.prefix(8).map { QuickAction.custom($0) }
        guard let match = matchNamed(query, titles: candidates.map(\.title)) else {
            core.showMessage(
                query.isEmpty
                    ? "Name an Action after @action, or pick one from the + menu."
                    : "No Action matches “\(query)”. Pick one from the + menu.",
                tone: .neutral)
            return
        }
        guard
            let action = candidates.first(where: { $0.title.caseInsensitiveCompare(match) == .orderedSame })
        else { return }
        attachAction(to: chat, action: action)
    }

    private func prepareIntegrationToken(_ query: String, in chat: AIChatState) {
        let servers = core.mcpCoordinator.servers
        let titles = servers.map { $0.title.isEmpty ? $0.slug : $0.title } + servers.map(\.slug)
        guard let match = matchNamed(query, titles: titles),
            let server = servers.first(where: {
                $0.slug.caseInsensitiveCompare(match) == .orderedSame
                    || $0.title.caseInsensitiveCompare(match) == .orderedSame
            })
        else {
            core.showMessage(
                query.isEmpty
                    ? "Name an integration after @integration, or pick one from the + menu."
                    : "No integration matches “\(query)”. Pick one from the + menu.",
                tone: .neutral)
            return
        }
        attachIntegration(to: chat, server: server)
    }

    private func prepareToolToken(_ query: String, in chat: AIChatState) {
        let tools = chatCoordinator.contextTools(for: chat)
        let titles = tools.flatMap { [$0.title, $0.name] }
        guard let match = matchNamed(query, titles: titles),
            let tool = tools.first(where: {
                $0.name.caseInsensitiveCompare(match) == .orderedSame
                    || $0.title.caseInsensitiveCompare(match) == .orderedSame
            })
        else {
            core.showMessage(
                query.isEmpty
                    ? "Name a tool after @tool, or pick one from the + menu."
                    : "No tool matches “\(query)”. Pick one from the + menu.",
                tone: .neutral)
            return
        }
        attachTool(to: chat, tool: tool)
    }

    private func matchNamed(_ query: String, titles: [String]) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let exact = titles.first(where: { $0.caseInsensitiveCompare(needle) == .orderedSame }) {
            return exact
        }
        return titles.first {
            $0.localizedCaseInsensitiveContains(needle) || needle.localizedCaseInsensitiveContains($0)
        }
    }
}
