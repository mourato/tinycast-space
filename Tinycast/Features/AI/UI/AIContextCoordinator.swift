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
    /// True when the listed browser's front window reported private; auto-attach refuses.
    private(set) var frontTabIsPrivate = false
    /// The browser the last entry was summoned from; listing falls back to any running one.
    @ObservationIgnored private var preferredBrowserID: String?
    @ObservationIgnored private var tabsTask: Task<Void, Never>?
    @ObservationIgnored private var captureTasks: [CaptureSlot: Task<Void, Never>] = [:]
    @ObservationIgnored private var captureTickets: [CaptureSlot: ContextPolicy.CaptureTicket] = [:]
    /// Every staged context attachment, so disabling a source drops its quotes, never files.
    @ObservationIgnored private var contextAttachments: [UUID: (chatID: UUID, source: ContextSource)] = [:]
    @ObservationIgnored private var autoAttachedKeys: [UUID: Set<String>] = [:]

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
        preferBrowser(of: snapshot)
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
        preferBrowser(of: windowSnapshot)
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
            let snapshot, !snapshot.isBrowser
        {
            return true
        }
        return browserAutoApplies(snapshot: snapshot)
    }

    private func preferBrowser(of snapshot: ContextAppReader.Snapshot?) {
        let bundleID = snapshot?.bundleIdentifier
        preferredBrowserID = ContextBrowser.isSupported(bundleID: bundleID) ? bundleID : nil
    }

    /// Browser auto reads the summoning browser's own tab, so it applies only from one.
    private func browserAutoApplies(snapshot: ContextAppReader.Snapshot?) -> Bool {
        guard
            ContextPolicy.canAutoAttachBrowser(options: options, aiEnabled: settings.aiEnabled)
        else { return false }
        return ContextBrowser.isSupported(bundleID: snapshot?.bundleIdentifier)
    }

    private func autoAttachBrowserIfAllowed(
        chat: AIChatState, snapshot: ContextAppReader.Snapshot?
    ) {
        guard browserAutoApplies(snapshot: snapshot) else { return }
        let ticket = ContextPolicy.CaptureTicket(
            operationID: UUID(), chatID: chat.session.id, sourceKey: snapshot?.sourceKey ?? "",
            generation: chat.stagingGeneration, source: .browserTabs, automatic: true)
        beginCapture(ticket: ticket)
        let slot = CaptureSlot(chatID: ticket.chatID, source: ticket.source)
        captureTasks[slot] = Task { [weak self] in
            guard let self else { return }
            defer { retire(ticket: ticket) }
            guard checkTicket(ticket, chat: chat) else { return }
            let result = await ContextBrowserRunner.listTabs(
                preferredBundleID: snapshot?.bundleIdentifier)
            guard checkTicket(ticket, chat: chat) else { return }
            switch result {
            case .failure(let failure):
                if failure.needsUserFix { core.showMessage(failure.message, tone: .neutral) }
            case .success(let listed):
                tabs = listed.tabs
                frontTabIsPrivate = listed.frontIsPrivate
                guard !listed.frontIsPrivate,
                    listed.browser.bundleID == snapshot?.bundleIdentifier,
                    let active = ContextBrowser.activeTab(in: listed.tabs),
                    shouldAutoStage(chat: chat, sourceKey: active.sourceKey)
                else { return }
                let resolved = ContextPolicy.CaptureTicket(
                    operationID: ticket.operationID, chatID: ticket.chatID,
                    sourceKey: active.sourceKey, generation: ticket.generation,
                    source: .browserTabs, automatic: true)
                captureTickets[slot] = resolved
                let read = await ContextBrowserRunner.readTab(active)
                publishTabRead(read, ticket: resolved, chat: chat, tab: active)
            }
        }
    }

    // MARK: - Manual capture

    func attachAppContext(
        to chat: AIChatState, snapshot: ContextAppReader.Snapshot?, automatic: Bool,
        onStaged: (@MainActor () -> Void)? = nil
    ) {
        let options = options
        guard ContextPolicy.canCaptureApp(
            options: options, aiEnabled: settings.aiEnabled, isBrowser: snapshot?.isBrowser ?? false)
        else {
            if !automatic {
                core.showMessage(
                    snapshot?.isBrowser == true
                        ? "Use Browser tabs to attach browser context safely."
                        : "Turn on app context in Settings → Context.", tone: .neutral)
            }
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
            generation: chat.stagingGeneration, source: .apps, automatic: automatic)
        beginCapture(ticket: ticket)
        captureTasks[CaptureSlot(chatID: ticket.chatID, source: .apps)] = Task { [weak self] in
            guard let self else { return }
            defer { retire(ticket: ticket) }
            guard checkTicket(ticket, chat: chat) else { return }
            let read = await ContextAppReader.read(snapshot)
            if publishAppRead(read, ticket: ticket, chat: chat, snapshot: snapshot) {
                onStaged?()
            }
        }
    }

    private func publishAppRead(
        _ read: ContextAppReader.Read, ticket: ContextPolicy.CaptureTicket, chat: AIChatState,
        snapshot: ContextAppReader.Snapshot
    ) -> Bool {
        guard checkTicket(ticket, chat: chat) else { return false }
        if read.accessDenied {
            core.showMessage(
                "Tinycast needs Accessibility access to quote apps. "
                    + "Grant it in System Settings → Privacy & Security → Accessibility.",
                tone: .neutral)
            return false
        }
        if read.windowChanged {
            if !ticket.automatic {
                core.showMessage(
                    "That window moved while reading — try again.", tone: .neutral)
            }
            return false
        }
        let current = options
        guard let body = ContextPolicy.resolveBody(
            selection: read.selection, full: read.value, selectionOnly: current.selectionOnly)
        else {
            if !ticket.automatic {
                core.showMessage(
                    read.skippedSecureInput
                        ? "That window is showing secure text, which Tinycast never reads."
                        : "No readable text in \(snapshot.name) — select something first.",
                    tone: .neutral)
            }
            return false
        }
        let title =
            read.windowTitle.map { "\(snapshot.name) — \($0)" } ?? snapshot.name
        let payload = ContextPolicy.compose(
            source: .apps, title: title, origin: snapshot.bundleIdentifier ?? snapshot.name,
            body: body, includeOrigin: current.includeOrigin,
            upstreamTruncated: read.isTruncated)
        return stage(payload, ticket: ticket, chat: chat, source: .apps)
    }

    func attachBrowserTab(
        to chat: AIChatState, tab: ContextBrowser.BrowserTab, automatic: Bool,
        onStaged: (@MainActor () -> Void)? = nil
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
            generation: chat.stagingGeneration, source: .browserTabs, automatic: automatic)
        beginCapture(ticket: ticket)
        let slot = CaptureSlot(chatID: ticket.chatID, source: .browserTabs)
        captureTasks[slot] = Task { [weak self] in
            guard let self else { return }
            defer { retire(ticket: ticket) }
            guard checkTicket(ticket, chat: chat) else { return }
            let result = await ContextBrowserRunner.readTab(tab)
            if publishTabRead(result, ticket: ticket, chat: chat, tab: tab) {
                onStaged?()
            }
        }
    }

    @discardableResult
    private func publishTabRead(
        _ result: Result<ContextBrowser.PageRead, ContextBrowser.ReadFailure>,
        ticket: ContextPolicy.CaptureTicket, chat: AIChatState, tab: ContextBrowser.BrowserTab
    ) -> Bool {
        guard checkTicket(ticket, chat: chat) else { return false }
        let current = options
        switch result {
        case .failure(let failure):
            if !ticket.automatic || failure.needsUserFix {
                core.showMessage(failure.message, tone: .neutral)
            }
            return false
        case .success(let read):
            guard
                let body = ContextPolicy.resolveBody(
                    selection: read.selection, full: read.body,
                    selectionOnly: current.selectionOnly)
            else {
                if !ticket.automatic { core.showMessage(ContextBrowser.ReadFailure.empty.message, tone: .neutral) }
                return false
            }
            let payload = ContextPolicy.compose(
                source: .browserTabs, title: tab.title.isEmpty ? (tab.host ?? "Browser tab") : tab.title,
                origin: ContextBrowser.sanitizedOrigin(url: read.url),
                body: body, includeOrigin: current.includeOrigin,
                upstreamTruncated: read.isTruncated)
            return stage(payload, ticket: ticket, chat: chat, source: .browserTabs)
        }
    }

    /// Quick Action descriptions ride as context; running one is never on offer here.
    @discardableResult
    func attachAction(to chat: AIChatState, action: QuickAction) -> Bool {
        guard
            ContextPolicy.allowsManual(
                source: .actions, options: options, aiEnabled: settings.aiEnabled)
        else {
            core.showMessage("Turn on Actions in Settings → Context → Context Items.", tone: .neutral)
            return false
        }
        let text = "Action: \(action.title)\n\n\(QuickActionPrompt.instructions(for: action))"
        guard
            let body = ContextPolicy.resolveBody(
                selection: nil, full: text, selectionOnly: false)
        else { return false }
        let payload = ContextPolicy.compose(
            source: .actions, title: action.title, origin: nil, body: body,
            includeOrigin: options.includeOrigin)
        return stage(payload, ticket: nil, chat: chat, source: .actions)
    }

    /// Server metadata rides as context; it neither enables the server nor calls anything.
    @discardableResult
    func attachIntegration(to chat: AIChatState, server: MCPServer) -> Bool {
        guard settings.aiEnabled, settings.mcpEnabled else {
            core.showMessage("Turn on AI and MCP to quote an integration.", tone: .neutral)
            return false
        }
        guard
            ContextPolicy.allowsManual(
                source: .integrations, options: options, aiEnabled: settings.aiEnabled),
            core.mcpCoordinator.server(slug: server.slug) != nil,
            chat.toolScope.allows(server.slug)
        else {
            core.showMessage("That integration isn't available to this chat.", tone: .neutral)
            return false
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
        else { return false }
        let payload = ContextPolicy.compose(
            source: .integrations, title: server.title.isEmpty ? server.slug : server.title,
            origin: nil, body: body, includeOrigin: options.includeOrigin)
        return stage(payload, ticket: nil, chat: chat, source: .integrations)
    }

    /// Tool metadata rides as context; the tool itself is never called because it was attached.
    @discardableResult
    func attachTool(to chat: AIChatState, tool: AITool) -> Bool {
        guard settings.aiEnabled, settings.mcpEnabled else {
            core.showMessage("Turn on AI and MCP to quote a tool.", tone: .neutral)
            return false
        }
        guard ContextPolicy.allowsManual(
            source: .tools, options: options, aiEnabled: settings.aiEnabled)
        else {
            core.showMessage("Turn on Tools in Settings → Context → Context Items.", tone: .neutral)
            return false
        }
        guard chatCoordinator.capabilities(for: chat).tools else {
            core.showMessage("This model can't call tools. Switch model to use them.", tone: .neutral)
            return false
        }
        if let route = MCPToolName.parse(tool.name), !chat.toolScope.allows(route.slug) {
            core.showMessage("That tool isn't available to this chat.", tone: .neutral)
            return false
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
        else { return false }
        let payload = ContextPolicy.compose(
            source: .tools, title: tool.title, origin: nil, body: body,
            includeOrigin: options.includeOrigin)
        return stage(payload, ticket: nil, chat: chat, source: .tools)
    }

    // MARK: - Capture ownership

    private func beginCapture(ticket: ContextPolicy.CaptureTicket) {
        let slot = CaptureSlot(chatID: ticket.chatID, source: ticket.source)
        captureTasks[slot]?.cancel()
        captureTickets[slot] = ticket
    }

    private func checkTicket(_ ticket: ContextPolicy.CaptureTicket, chat: AIChatState) -> Bool {
        guard ticket.chatID == chat.session.id else { return false }
        let slot = CaptureSlot(chatID: ticket.chatID, source: ticket.source)
        guard let latest = captureTickets[slot] else { return false }
        return ContextPolicy.shouldPublish(
            ticket: ticket, latest: latest, latestCancelled: Task.isCancelled,
            captureAllowed: ContextPolicy.allowsCapture(
                ticket: ticket, options: options, aiEnabled: settings.aiEnabled),
            currentGeneration: chat.stagingGeneration)
    }

    private func retire(ticket: ContextPolicy.CaptureTicket) {
        let slot = CaptureSlot(chatID: ticket.chatID, source: ticket.source)
        guard captureTickets[slot]?.operationID == ticket.operationID else { return }
        captureTickets[slot] = nil
        captureTasks[slot] = nil
    }

    private func stage(
        _ payload: ContextPolicy.Payload, ticket: ContextPolicy.CaptureTicket?,
        chat: AIChatState, source: ContextSource
    ) -> Bool {
        let attachment = ChatAttachment(
            payload: .document(payload.document), name: payload.name, preview: nil)
        if let refusal = chat.attach(attachment) {
            core.showMessage(refusal.message, tone: .neutral)
            return false
        }
        contextAttachments[attachment.id] = (chat.session.id, source)
        if let ticket, ticket.automatic {
            autoAttachedKeys[chat.session.id, default: []].insert(ticket.sourceKey)
        }
        if payload.isPartial {
            core.showMessage(
                "Attached a shortened quote — the full text didn't fit.", tone: .neutral)
        }
        return true
    }

    private func shouldAutoStage(chat: AIChatState, sourceKey: String) -> Bool {
        let onlyContext = chat.pendingAttachments.allSatisfy { contextAttachments[$0.id] != nil }
        return onlyContext && autoAttachedKeys[chat.session.id]?.contains(sourceKey) != true
    }

    func cancelAllCaptures() {
        for task in captureTasks.values { task.cancel() }
        tabsTask?.cancel()
        captureTasks = [:]
        captureTickets = [:]
        tabsTask = nil
    }

    func optionsDidChange() {
        for (slot, ticket) in captureTickets where !ContextPolicy.allowsCapture(
            ticket: ticket, options: options, aiEnabled: settings.aiEnabled)
        {
            captureTasks[slot]?.cancel()
            captureTasks[slot] = nil
            captureTickets[slot] = nil
        }
        if !ContextPolicy.canCaptureBrowser(options: options, aiEnabled: settings.aiEnabled) {
            tabsTask?.cancel()
            tabsTask = nil
            tabs = []
            frontTabIsPrivate = false
        }
        dropDisallowedContext()
    }

    private func dropDisallowedContext() {
        for chat in chatCoordinator.chats.live {
            for attachment in chat.pendingAttachments {
                guard let entry = contextAttachments[attachment.id],
                    !ContextPolicy.allowsManual(
                        source: entry.source, options: options, aiEnabled: settings.aiEnabled)
                else { continue }
                chat.removeAttachment(attachment.id)
                contextAttachments[attachment.id] = nil
            }
        }
    }

    func noteRemoved(_ id: UUID) {
        contextAttachments[id] = nil
    }

    func noteCleared(in chat: AIChatState) {
        contextAttachments = contextAttachments.filter { $0.value.chatID != chat.session.id }
    }

    func forget(chatID: UUID) {
        for slot in captureTasks.keys where slot.chatID == chatID {
            captureTasks[slot]?.cancel()
            captureTasks[slot] = nil
            captureTickets[slot] = nil
        }
        autoAttachedKeys[chatID] = nil
        contextAttachments = contextAttachments.filter { $0.value.chatID != chatID }
    }

    // MARK: - Tabs

    func refreshTabsIfAllowed() {
        guard
            ContextPolicy.canCaptureBrowser(options: options, aiEnabled: settings.aiEnabled)
        else { return }
        tabsTask?.cancel()
        let preferred = preferredBrowserID
        tabsTask = Task { [weak self] in
            let result = await ContextBrowserRunner.listTabs(preferredBundleID: preferred)
            guard let self, !Task.isCancelled else { return }
            if case .success(let listed) = result {
                self.tabs = listed.tabs
                self.frontTabIsPrivate = listed.frontIsPrivate
            }
        }
    }

    var activeTab: ContextBrowser.BrowserTab? { ContextBrowser.activeTab(in: tabs) }

}
