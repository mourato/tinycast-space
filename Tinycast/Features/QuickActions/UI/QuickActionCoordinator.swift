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
                    title: String(localized: "Enable Quick Actions?"),
                    message: String(
                        localized: """
                            Tinycast needs the Accessibility permission to read the text you have \
                            selected in other apps and replace it. Nothing is read until you press \
                            a shortcut.
                            """),
                    symbol: "wand.and.sparkles", confirmTitle: String(localized: "Continue"),
                    tone: .neutral,
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
                title: String(localized: "Delete “\(action.name)”?"),
                message: String(localized: "Its instructions, shortcut and learned ranking go with it."),
                symbol: action.symbol, confirmTitle: String(localized: "Delete"))
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
                title: String(localized: "Couldn’t Save the Change"), message: error.localizedDescription,
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
        let selection: String
        var fromPage = false
        do {
            switch target {
            case .external(let app):
                do {
                    selection = try await QuickActionRunner.selection(in: app, using: injector)
                } catch let failure as QuickActionFailure where Self.pageMayStandIn(for: failure) {
                    guard let page = await pageText(in: app) else { throw failure }
                    guard !Task.isCancelled else { return }
                    switch page {
                    case .success(let text): selection = text
                    case .failure(let refusal):
                        core.showMessage(refusal.message, tone: .neutral)
                        return
                    }
                    fromPage = true
                }
            case .note(let note):
                selection = try QuickActionRunner.accepted(note.text)
            }
        } catch let failure as QuickActionFailure {
            reportRefusal(failure)
            return
        } catch {
            core.showMessage(error.localizedDescription, tone: .danger)
            return
        }
        guard !Task.isCancelled else { return }
        // A page has no selection to write back into, so its result is only ever read.
        let writesBack = !fromPage && action.replacesSelection
        let sourceName = fromPage ? "Page text" : "Selected text"
        if action.usesTranslationFramework {
            await translate(
                selection, sourceName: sourceName, action: action, target: target,
                writesBack: writesBack)
        } else {
            answer(
                action, selection: selection, sourceName: sourceName, target: target,
                writesBack: writesBack)
        }
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
                    title: String(localized: "Quick Actions can't read your selection"),
                    message: String(
                        localized: """
                            Tinycast needs the Accessibility permission to read the text you have \
                            selected and replace it. If Tinycast is already listed, switch it off \
                            and on again — a rebuilt app keeps a stale entry.
                            """),
                    symbol: "wand.and.sparkles", recovery: String(localized: "Open System Settings"))
            else { return }
            Permissions.openAccessibilitySettings()
        }
    }

    /// A new conversation whose text rides as a staged document, answered by the chat's own route.
    private func answer(
        _ action: QuickAction, selection: String, sourceName: String, target: Target,
        writesBack: Bool
    ) {
        let chat = core.aiChatCoordinator.chats.quickAI
        chat.startNewChat()
        pendingReply = nil
        let attachment = ChatAttachment(
            payload: .document(
                AIDocument(data: Data(selection.utf8), mimeType: "text/plain", name: sourceName)),
            name: sourceName, preview: nil)
        if let refusal = chat.attach(attachment) {
            core.showMessage(refusal.message, tone: .neutral)
            return
        }
        let chatID = chat.session.id
        if writesBack {
            var automatic = false
            if case .custom(let custom) = action { automatic = !custom.previewsResult }
            chat.onNextReplyEnded = { [weak self] reply in
                guard let self, let reply else { return }
                self.finishedReply(
                    reply, chatID: chatID, action: action, target: target, automatic: automatic)
            }
        }
        paletteCoordinator.showPalette(mode: .ai)
        let instructions = QuickActionPrompt.instructions(
            for: action, override: store.settings.instructionOverride(for: action))
        let sent = core.aiChatCoordinator.answerQuickAction(
            prompt: action.title, instructions: instructions, in: chat)
        if !sent { chat.onNextReplyEnded = nil }
    }

    /// Apple's translator does not stream, so its reply is recorded whole as a finished turn.
    private func translate(
        _ selection: String, sourceName: String, action: QuickAction, target: Target,
        writesBack: Bool
    ) async {
        let chat = core.aiChatCoordinator.chats.quickAI
        chat.startNewChat()
        pendingReply = nil
        paletteCoordinator.showPalette(mode: .ai)
        let language = targetLanguage
        let languageName = TextTranslator.displayName(of: language)
        core.showProgress("Translating…")
        defer { core.hideProgress() }
        do {
            let text = try await TextTranslator.translate(selection, to: language)
            guard !Task.isCancelled else { return }
            let document = AIDocument(
                data: Data(selection.utf8), mimeType: "text/plain", name: sourceName)
            let messageID = chat.record(
                prompt: "\(action.title) to \(languageName)", documents: [document], reply: text)
            if writesBack {
                pendingReply = PendingReply(
                    chatID: chat.session.id, messageID: messageID, action: action, target: target)
            }
        } catch let failure as TextTranslator.Failure where failure.needsDownload {
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
            chat.report(error.localizedDescription)
        }
    }

    /// Automatic replacement leaves the palette, as a direct replacement always did; otherwise the reply waits for its button.
    private func finishedReply(
        _ reply: ChatMessage, chatID: UUID, action: QuickAction, target: Target, automatic: Bool
    ) {
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard automatic else {
            pendingReply = PendingReply(
                chatID: chatID, messageID: reply.id, action: action, target: target)
            return
        }
        paletteCoordinator.hidePalette(restoreFocus: target.isNote)
        deliver(text, to: target, action: action)
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
            self?.core.showMessage(String(localized: "\(action.title) applied"))
        }
        let onFailed: @MainActor @Sendable () -> Void = { [weak self] in
            Paster.copyPlainText(text)
            self?.core.showMessage(
                String(localized: "\(action.title) couldn't replace the selection — copied instead"),
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
