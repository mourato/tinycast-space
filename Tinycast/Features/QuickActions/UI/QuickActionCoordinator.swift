import AppKit
import Observation

/// The single funnel for every Quick Action, however it was started. Every result lands in Quick AI.
@MainActor
@Observable
final class QuickActionCoordinator {
    private struct NoteSelection {
        let editor: NoteTextView
        let document: NoteEditorInput
        let range: NSRange
        let text: String
    }

    private enum Target {
        case external(NSRunningApplication?)
        case note(NoteSelection)

        var isNote: Bool {
            if case .note = self { return true }
            return false
        }
    }

    /// The reply that may still be written back, and the chat it was written in.
    private struct PendingReply {
        let chatID: UUID
        let messageID: UUID
        let action: QuickAction
        let target: Target
    }

    private let settings: AppSettings
    private let store: QuickActionSettingsStore
    private let customActions: CustomQuickActionStore
    private let injector: TextInjector
    private let appIndex: AppIndex
    private let hotKeys: HotKeyManager
    private let favorites: FavoritesStore
    private let visibility: VisibilityStore
    private let ranking: LauncherRankingStore
    private let aliases: AliasStore
    private let paletteCoordinator: PaletteCoordinator
    private unowned let core: AppCore

    private static let launcherCommands = Set(BuiltInQuickAction.allCases.map(CommandID.init))
    private static let languageSettingsPane = "com.apple.Localization-Settings.extension"

    /// One at a time while the text is read: two reads race for one selection.
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingReply: PendingReply?

    init(
        settings: AppSettings, store: QuickActionSettingsStore,
        customActions: CustomQuickActionStore, injector: TextInjector,
        appIndex: AppIndex, hotKeys: HotKeyManager, favorites: FavoritesStore,
        visibility: VisibilityStore, ranking: LauncherRankingStore, aliases: AliasStore,
        paletteCoordinator: PaletteCoordinator, core: AppCore
    ) {
        self.settings = settings
        self.store = store
        self.customActions = customActions
        self.injector = injector
        self.appIndex = appIndex
        self.hotKeys = hotKeys
        self.favorites = favorites
        self.visibility = visibility
        self.ranking = ranking
        self.aliases = aliases
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    /// Launcher rows come and go with the switch; the Carbon bindings stay registered.
    func applyEnabled() {
        appIndex.setCommandsVisible(Self.launcherCommands, settings.quickActionsEnabled)
        applyCustomQuickActionsPresence()
        guard settings.quickActionsEnabled else {
            cancel()
            core.applyInstalledAILifecycle()
            return
        }
        core.applyInstalledAILifecycle()
        loadLanguages()
    }

    /// Enabling is consent: reading a selection and typing over it both need Accessibility.
    func setEnabled(_ enabled: Bool) {
        guard enabled != settings.quickActionsEnabled else { return }
        guard enabled else {
            settings.quickActionsEnabled = false
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: "Enable Quick Actions?",
                    message:
                        "Tinycast needs the Accessibility permission to read the text you have "
                        + "selected in other apps and replace it. Nothing is read until you press "
                        + "a shortcut.",
                    symbol: "wand.and.sparkles", confirmTitle: "Continue", tone: .neutral,
                    confirmRole: .standard)
            else { return }
            settings.quickActionsEnabled = true
            // The one prompt for this feature, raised from the gesture that asked for it.
            Permissions.ensureAccessibility()
        }
    }

    func applyCustomQuickActionsPresence() {
        appIndex.setCustomQuickActions(
            settings.quickActionsEnabled ? customActions.actions : [])
    }

    // MARK: - The reader's own actions

    // MARK: - The reader's own actions

    func addCustomQuickAction(_ draft: CustomQuickAction) throws(CustomQuickActionError) {
        _ = try customActions.add(draft)
    }

    func updateCustomQuickAction(_ draft: CustomQuickAction) throws(CustomQuickActionError) {
        try customActions.update(draft)
    }

    func setPreviewsResult(_ previews: Bool, id: UUID) {
        do {
            try customActions.setPreviewsResult(previews, id: id)
        } catch {
            report(error)
        }
    }

    func deleteCustomQuickAction(id: UUID) async {
        guard let action = customActions.action(id: id) else { return }
        guard
            await core.confirm(
                title: "Delete “\(action.name)”?",
                message: "Its instructions, shortcut and learned ranking go with it.",
                symbol: action.symbol, confirmTitle: "Delete")
        else { return }
        // Unwound only once the row is gone, so a kept record never loses its shortcut.
        do {
            guard let removed = try customActions.remove(id: id) else { return }
            removeCustomQuickActionReferences(removed)
        } catch {
            report(error)
        }
    }

    private func report(_ error: CustomQuickActionError) {
        Task {
            await core.showNotice(
                title: "Couldn’t Save the Change", message: error.localizedDescription,
                symbol: CustomQuickAction.sfSymbol, tone: .danger)
        }
    }

    private func removeCustomQuickActionReferences(_ action: CustomQuickAction) {
        let hotKeyAction = HotKeyAction.quickAction(id: action.id)
        if hotKeys.recordingAction == hotKeyAction { hotKeys.recordingAction = nil }
        hotKeys.setBinding(nil, for: hotKeyAction)
        favorites.remove(keys: [action.entryID])
        visibility.removeItemKeys([action.entryID])
        aliases.removeKeys([action.entryID])
        ranking.reset(itemKey: action.entryID)
    }

    func run(id: UUID) {
        guard let action = customActions.action(id: id) else { return }
        run(.custom(action))
    }

    func run(_ action: QuickAction) {
        guard settings.quickActionsEnabled, running == nil else { return }
        guard settings.aiEnabled else {
            core.showMessage("Turn on AI Chat to use Quick Actions.", tone: .neutral)
            return
        }
        guard !core.aiChatCoordinator.chats.quickAI.isStreaming else {
            core.showMessage("Quick AI is still answering.", tone: .neutral)
            return
        }
        let source =
            paletteCoordinator.isVisible
            ? InjectionTarget.behindPalette(
                ownWindow: paletteCoordinator.previousOwnWindow, app: paletteCoordinator.targetApp)
            : InjectionTarget.current()
        let target: Target
        if let editor = source?.ownEditor as? NoteTextView {
            target = .note(
                NoteSelection(
                    editor: editor, document: core.notesCoordinator.editorInput,
                    range: editor.selectedRange(), text: editor.injectableSelection))
        } else {
            target = .external(paletteCoordinator.targetApp)
        }
        if paletteCoordinator.isVisible {
            paletteCoordinator.hidePalette(restoreFocus: source?.ownEditor is NoteTextView)
        }
        start { [weak self] in await self?.begin(action, target: target) }
    }

    func cancel() {
        generation += 1
        running?.cancel()
        running = nil
        core.hideProgress()
        core.aiChatCoordinator.chats.quickAI.clearProgressNotice()
    }

    /// The generation stops a superseded task from clearing the newer handle as it finishes.
    private func start(_ work: @escaping @MainActor () async -> Void) {
        generation += 1
        let mine = generation
        running?.cancel()
        running = Task { [weak self] in
            await work()
            guard let self, mine == self.generation else { return }
            self.running = nil
        }
    }

    private func begin(_ action: QuickAction, target: Target) async {
        switch target {
        case .note(let note):
            await beginFromNote(action, note: note, target: target)
        case .external(let app):
            await beginExternal(action, app: app, target: target)
        }
    }

    private func beginFromNote(_ action: QuickAction, note: NoteSelection, target: Target) async {
        let selection: String
        do {
            selection = try QuickActionRunner.accepted(note.text)
        } catch let failure as QuickActionFailure {
            reportRefusal(failure)
            return
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        guard !Task.isCancelled else { return }
        let writesBack = action.replacesSelection
        let silently = writesBack && store.settings.replacesOnly(action)
        let sourceName = "Selected text"
        if action.usesTranslationFramework {
            await translate(
                selection, sourceName: sourceName, action: action, target: target,
                writesBack: writesBack, silently: silently)
        } else {
            answer(
                action, selection: selection, sourceName: sourceName, target: target,
                writesBack: writesBack, silently: silently)
        }
    }

    private func beginExternal(
        _ action: QuickAction, app: NSRunningApplication?, target: Target
    ) async {
        let replacesOnly = store.settings.replacesOnly(action)
        var previews = !replacesOnly
        let mine = generation
        var prepared: PreparedCapture?
        if previews {
            guard !Task.isCancelled, mine == generation else { return }
            guard settings.quickActionsEnabled, settings.aiEnabled else { return }
            prepared = preparePreview()
        } else {
            guard !Task.isCancelled, mine == generation else { return }
            guard settings.quickActionsEnabled, settings.aiEnabled else { return }
            core.showProgress(action.progressTitle, onCancel: { [weak self] in self?.cancel() })
        }
        // The palette may now be key: capture still posts to the retained app's pid.
        let selection: String
        var fromPage = false
        do {
            do {
                selection = try await QuickActionRunner.selection(in: app, using: injector)
            } catch let failure as QuickActionFailure where Self.pageMayStandIn(for: failure) {
                if !previews {
                    guard
                        ContextBrowser.quickActionFallbackApplies(
                            bundleID: app?.bundleIdentifier,
                            options: settings.contextPolicyOptions,
                            aiEnabled: settings.aiEnabled)
                    else { throw failure }
                    core.hideProgress()
                    guard !Task.isCancelled, mine == generation else { return }
                    guard settings.quickActionsEnabled, settings.aiEnabled else { return }
                    prepared = preparePreview()
                    previews = true
                }
                guard let page = await pageText(in: app) else { throw failure }
                switch page {
                case .success(let text): selection = text
                case .failure(let refusal):
                    guard let snapshot = prepared, let chat = preparedChat(matching: snapshot, mine: mine)
                    else {
                        dropStaleCapture()
                        return
                    }
                    paletteCoordinator.claimKey()
                    chat.report(refusal.message)
                    return
                }
                fromPage = true
            }
        } catch let failure as QuickActionFailure {
            if let snapshot = prepared, let chat = preparedChat(matching: snapshot, mine: mine) {
                paletteCoordinator.claimKey()
                chat.report(failure.localizedDescription)
                return
            }
            if previews {
                dropStaleCapture()
                return
            }
            core.hideProgress()
            guard !Task.isCancelled, mine == generation else { return }
            reportRefusal(failure)
            return
        } catch {
            if let snapshot = prepared, let chat = preparedChat(matching: snapshot, mine: mine) {
                paletteCoordinator.claimKey()
                chat.report(error.localizedDescription)
                return
            }
            if previews {
                dropStaleCapture()
                return
            }
            core.hideProgress()
            guard !Task.isCancelled, mine == generation else { return }
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        let writesBack = action.replacesSelection && !fromPage
        let silently = writesBack && replacesOnly
        let sourceName = fromPage ? "Page text" : "Selected text"
        if previews {
            guard let snapshot = prepared else { return }
            if action.usesTranslationFramework {
                await translate(
                    selection, sourceName: sourceName, action: action, target: target,
                    writesBack: writesBack, silently: silently, prepared: snapshot, mine: mine)
            } else {
                answer(
                    action, selection: selection, sourceName: sourceName, target: target,
                    writesBack: writesBack, silently: silently, prepared: snapshot, mine: mine)
            }
            return
        }
        core.hideProgress()
        guard !Task.isCancelled, mine == generation else { return }
        guard settings.quickActionsEnabled, settings.aiEnabled else { return }
        if action.usesTranslationFramework {
            await translate(
                selection, sourceName: sourceName, action: action, target: target,
                writesBack: writesBack, silently: silently)
        } else {
            answer(
                action, selection: selection, sourceName: sourceName, target: target,
                writesBack: writesBack, silently: silently)
        }
    }

    /// What the read must still find: the same chat, empty and unstreamed, still on screen.
    private struct PreparedCapture {
        let sessionID: UUID
        let stagingGeneration: Int
        let dismissalGeneration: Int
    }

    private static let gatheringMessage = "Gathering selected text…"

    private func preparePreview() -> PreparedCapture {
        let chat = core.aiChatCoordinator.chats.quickAI
        chat.startNewChat()
        pendingReply = nil
        chat.reportProgress(Self.gatheringMessage)
        // Unkeyed: the borrowed ⌘C activates the retained app, which would hide a key window.
        paletteCoordinator.showPalette(mode: .ai, takingKey: false)
        return PreparedCapture(
            sessionID: chat.session.id, stagingGeneration: chat.stagingGeneration,
            dismissalGeneration: paletteCoordinator.dismissalGeneration)
    }

    /// The prepared chat while it is still the one on screen and empty; anything else drops it.
    private func preparedChat(matching prepared: PreparedCapture, mine: Int) -> AIChatState? {
        guard !Task.isCancelled, mine == generation else { return nil }
        guard settings.quickActionsEnabled, settings.aiEnabled else { return nil }
        let chat = core.aiChatCoordinator.chats.quickAI
        guard chat.session.id == prepared.sessionID,
            chat.stagingGeneration == prepared.stagingGeneration,
            paletteCoordinator.dismissalGeneration == prepared.dismissalGeneration,
            !chat.isStreaming,
            chat.session.messages.isEmpty,
            chat.pendingAttachments.isEmpty,
            paletteCoordinator.isShowing(.ai)
        else { return nil }
        return chat
    }

    /// A dropped capture leaves no gathering notice for the next summon to explain.
    private func dropStaleCapture() {
        core.aiChatCoordinator.chats.quickAI.clearProgressNotice()
    }

    private static func pageMayStandIn(for failure: QuickActionFailure) -> Bool {
        switch failure {
        case .noSelection, .unreadableApp: return true
        default: return false
        }
    }

    /// The active tab's selection or text; nil when browser context is off or the app isn't one.
    private func pageText(
        in app: NSRunningApplication?
    ) async -> Result<String, ContextBrowser.ReadFailure>? {
        let bundleID = app?.bundleIdentifier
        guard
            ContextBrowser.quickActionFallbackApplies(
                bundleID: bundleID, options: settings.contextPolicyOptions,
                aiEnabled: settings.aiEnabled)
        else { return nil }
        let listed = await ContextBrowserRunner.listTabs(preferredBundleID: bundleID)
        guard !Task.isCancelled else { return nil }
        switch listed {
        case .failure(let failure):
            return failure.needsUserFix ? .failure(failure) : nil
        case .success(let list):
            if list.frontIsPrivate { return .failure(.restrictedPage) }
            guard list.browser.bundleID == bundleID,
                let active = ContextBrowser.activeTab(in: list.tabs)
            else { return nil }
            let read = await ContextBrowserRunner.readTab(active)
            guard !Task.isCancelled else { return nil }
            switch read {
            case .failure(let failure): return .failure(failure)
            case .success(let page):
                guard
                    let text = ContextBrowser.quickActionText(
                        page, limitBytes: QuickActionRunner.maxSelectionBytes)
                else { return .failure(.empty) }
                return .success(text)
            }
        }
    }

    /// A missing permission cannot be fixed from a pill that fades, so it earns a dialog instead.
    private func reportRefusal(_ failure: QuickActionFailure) {
        guard failure.opensAccessibilitySettings else {
            core.showMessage(failure.localizedDescription, tone: .danger)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.reportFailure(
                    title: "Quick Actions can't read your selection",
                    message:
                        "Tinycast needs the Accessibility permission to read the text you have "
                        + "selected and replace it. If Tinycast is already listed, switch it off "
                        + "and on again — a rebuilt app keeps a stale entry.",
                    symbol: "wand.and.sparkles", recovery: "Open System Settings")
            else { return }
            Permissions.openAccessibilitySettings()
        }
    }

    /// A new conversation whose text rides as a staged document, answered by the chat's own route.
    /// Replace only keeps the window shut: progress in the pill, and any failure in a HUD.
    private func answer(
        _ action: QuickAction, selection: String, sourceName: String, target: Target,
        writesBack: Bool, silently: Bool,
        prepared: PreparedCapture? = nil, mine: Int? = nil
    ) {
        let chat = core.aiChatCoordinator.chats.quickAI
        let isPrepared = prepared != nil && mine != nil
        if isPrepared {
            guard let prepared, let mine, preparedChat(matching: prepared, mine: mine) != nil
            else {
                dropStaleCapture()
                return
            }
            pendingReply = nil
            paletteCoordinator.claimKey()
        } else {
            chat.startNewChat()
            pendingReply = nil
        }
        let attachment = ChatAttachment(
            payload: .document(
                AIDocument(data: Data(selection.utf8), mimeType: "text/plain", name: sourceName)),
            name: sourceName, preview: nil)
        if let refusal = chat.attach(attachment) {
            if isPrepared {
                chat.report(refusal.message)
            } else {
                core.showMessage(refusal.message, tone: .neutral)
            }
            return
        }
        let chatID = chat.session.id
        if writesBack {
            chat.onNextReplyEnded = { [weak self] reply in
                self?.replyEnded(
                    reply, chatID: chatID, action: action, target: target, silently: silently)
            }
        }
        if !isPrepared {
            if silently {
                core.showProgress(action.progressTitle, onCancel: { [weak chat] in chat?.cancel() })
            } else {
                paletteCoordinator.showPalette(mode: .ai)
            }
        }
        let instructions = QuickActionPrompt.instructions(
            for: action, override: store.settings.instructionOverride(for: action))
        let sent = core.aiChatCoordinator.answerQuickAction(
            prompt: action.title, instructions: instructions, in: chat)
        if !sent {
            chat.onNextReplyEnded = nil
            if isPrepared {
                if chat.noticeIsProgress { chat.report("\(action.title) didn't start") }
            } else if silently {
                core.hideProgress()
                core.showMessage(chat.notice ?? "\(action.title) didn't start", tone: .danger)
            }
        }
    }

    /// Apple's translator does not stream, so its reply is recorded whole as a finished turn.
    private func translate(
        _ selection: String, sourceName: String, action: QuickAction, target: Target,
        writesBack: Bool, silently: Bool,
        prepared: PreparedCapture? = nil, mine: Int? = nil
    ) async {
        let chat = core.aiChatCoordinator.chats.quickAI
        if let prepared, let mine {
            guard preparedChat(matching: prepared, mine: mine) != nil else {
                dropStaleCapture()
                return
            }
            pendingReply = nil
            paletteCoordinator.claimKey()
        } else {
            chat.startNewChat()
            pendingReply = nil
            if !silently { paletteCoordinator.showPalette(mode: .ai) }
        }
        let language = targetLanguage
        let languageName = TextTranslator.displayName(of: language)
        core.showProgress(action.progressTitle)
        defer { core.hideProgress() }
        do {
            let text = try await TextTranslator.translate(selection, to: language)
            if let prepared, let mine {
                guard preparedChat(matching: prepared, mine: mine) != nil else {
                    dropStaleCapture()
                    return
                }
            } else {
                guard !Task.isCancelled else { return }
            }
            let document = AIDocument(
                data: Data(selection.utf8), mimeType: "text/plain", name: sourceName)
            let messageID = chat.record(
                prompt: "\(action.title) to \(languageName)", documents: [document], reply: text)
            guard writesBack else { return }
            if silently {
                writeBack(text, to: target, action: action)
            } else {
                pendingReply = PendingReply(
                    chatID: chat.session.id, messageID: messageID, action: action, target: target)
            }
        } catch let failure as TextTranslator.Failure where failure.needsDownload {
            if let prepared, let mine {
                guard preparedChat(matching: prepared, mine: mine) != nil else {
                    dropStaleCapture()
                    return
                }
            } else {
                guard !Task.isCancelled else { return }
            }
            guard
                await core.reportFailure(
                    title: "\(languageName) isn’t downloaded yet",
                    message:
                        "Download it in Language & Region, then translate again. Translation runs "
                        + "on this Mac, so the text stays here.",
                    symbol: "translate", recovery: "Open Language & Region")
            else { return }
            AppLauncher.openSettingsPane(bundleID: Self.languageSettingsPane)
        } catch {
            if silently {
                core.showMessage(error.localizedDescription, tone: .danger)
            } else if let prepared, let mine,
                let failedChat = preparedChat(matching: prepared, mine: mine)
            {
                paletteCoordinator.claimKey()
                failedChat.report(error.localizedDescription)
            } else if prepared != nil {
                dropStaleCapture()
            } else {
                chat.report(error.localizedDescription)
            }
        }
    }

    /// The reply has ended, however it ended. Replace only writes it back here, with no window to show it.
    private func replyEnded(
        _ reply: ChatMessage, chatID: UUID, action: QuickAction, target: Target, silently: Bool
    ) {
        if silently { core.hideProgress() }
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reply.state == .complete, !text.isEmpty else {
            if silently { core.showMessage("\(action.title) didn't finish", tone: .danger) }
            return
        }
        guard silently else {
            pendingReply = PendingReply(
                chatID: chatID, messageID: reply.id, action: action, target: target)
            return
        }
        writeBack(text, to: target, action: action)
    }

    /// A reply that lands in another app than the one it was asked of is copied, never pasted there.
    private func writeBack(_ text: String, to target: Target, action: QuickAction) {
        guard focusHeld(by: target) else {
            Paster.copyPlainText(text)
            core.showMessage("\(action.title) copied instead — the app changed", tone: .danger)
            return
        }
        deliver(text, to: target, action: action)
    }

    private func focusHeld(by target: Target) -> Bool {
        switch target {
        case .external(let app):
            guard let app else { return false }
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        // The editor is checked again on delivery, against the very range it was asked about.
        case .note: return true
        }
    }

    /// Quick AI asks this before offering its Replace button for the reply on screen.
    func canReplaceReply(in chat: AIChatState) -> Bool {
        guard let pending = pendingReply, pending.chatID == chat.session.id, !chat.isStreaming
        else { return false }
        return chat.session.messages.last?.id == pending.messageID
    }

    func replaceReply(in chat: AIChatState) {
        guard canReplaceReply(in: chat), let pending = pendingReply,
            let reply = chat.session.messages.last
        else { return }
        pendingReply = nil
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        paletteCoordinator.hidePalette(restoreFocus: pending.target.isNote)
        deliver(text, to: pending.target, action: pending.action)
    }

    /// A replacement that never lands would otherwise lose the reply, so the clipboard keeps it.
    private func deliver(_ text: String, to target: Target, action: QuickAction) {
        let onDelivered: @MainActor @Sendable () -> Void = { [weak self] in
            self?.core.showMessage("\(action.title) applied")
        }
        let onFailed: @MainActor @Sendable () -> Void = { [weak self] in
            Paster.copyPlainText(text)
            self?.core.showMessage(
                "\(action.title) couldn't replace the selection — copied instead",
                tone: .danger)
        }
        switch target {
        case .external(let app):
            injector.replaceSelection(
                with: text, in: app, onDelivered: onDelivered, onFailed: onFailed)
        case .note(let note):
            guard core.notesCoordinator.editorInput == note.document,
                note.editor.window?.isVisible == true,
                note.editor.replaceUnchangedSelection(
                    with: text, source: note.document.source, range: note.range)
            else { onFailed(); return }
            onDelivered()
        }
    }

    private var targetLanguage: Locale.Language {
        let stored = store.settings.targetLanguage
        guard !stored.isEmpty else { return Locale.current.language }
        return Locale.Language(identifier: stored)
    }

    /// Observed, not ignored: it arrives after the pane has painted, and the picker has to notice.
    private(set) var offeredLanguages: [Locale.Language] = []
    @ObservationIgnored private var languageLoad: Task<Void, Never>?

    func loadLanguages() {
        guard offeredLanguages.isEmpty, languageLoad == nil else { return }
        languageLoad = Task { [weak self] in
            let languages = await TextTranslator.supportedLanguages()
            self?.offeredLanguages = languages
        }
    }
}

extension TextTranslator.Failure {
    var needsDownload: Bool {
        if case .notInstalled = self { return true }
        return false
    }
}
