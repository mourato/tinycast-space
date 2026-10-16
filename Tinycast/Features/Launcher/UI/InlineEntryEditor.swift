import AppKit
import Carbon.HIToolbox
import SwiftUI

/// tinycast-space: edit a launcher entry's alias and shortcut in place, from its own ⌘K menu.
/// Ported from jhasubhash/tinycast (f509d005, AGPL-3.0) and reshaped so everything but a few one-line
/// hooks lives in this file: the menu rows, the alias draft, and the keys typed while it is open.
@MainActor
@Observable
final class InlineEntryEditor {
    static let shared = InlineEntryEditor()

    /// The alias key being edited on its ⌘K row, or nil.
    private(set) var aliasKey: String?
    /// What is typed while `aliasKey` is set; the row reads it live.
    private(set) var aliasDraft = ""
    @ObservationIgnored private weak var core: AppCore?

    private init() {}

    /// The rows an entry's ⌘K menu gains. Query-driven commands have no alias or shortcut to own.
    static func menuItems(for app: AppEntry, core: AppCore) -> [PopoverMenuItem] {
        guard !CommandCatalog.isQueryDriven(app) else { return [] }
        let key = app.preferenceKey
        var alias = PopoverMenuItem(
            title: "Change Alias", systemImage: "character.cursor.ibeam", startsSection: true
        ) {
            shared.beginAlias(key: key, core: core)
        }
        alias.trailingAccessory = { AnyView(MenuAliasBox(key: key)) }
        alias.keepsMenuOpen = true
        var items = [alias]
        if let action = hotKeyAction(for: app) {
            var shortcut = PopoverMenuItem(title: "Change Shortcut", systemImage: "command") {
                shared.end()
                core.hotKeys.recordingAction = action
            }
            shortcut.trailingAccessory = { AnyView(ShortcutRecorder(action: action)) }
            shortcut.keepsMenuOpen = true
            items.append(shortcut)
        }
        return items
    }

    /// `AppEntry.hotKeyAction` leaves extension commands out; their binding is keyed by entry ID.
    static func hotKeyAction(for app: AppEntry) -> HotKeyAction? {
        if let action = app.hotKeyAction { return action }
        return app.kind == .extensionCommand ? .extensionCommand(entryID: app.id) : nil
    }

    /// Seeds the draft with the saved alias; ↵ commits it, Esc drops it.
    private func beginAlias(key: String, core: AppCore) {
        core.hotKeys.recordingAction = nil
        self.core = core
        aliasDraft = core.aliases.alias(for: key) ?? ""
        aliasKey = key
    }

    /// Ends any inline edit: called when a row switches editors and when the menu closes.
    func end(stoppingRecordingIn core: AppCore? = nil) {
        aliasKey = nil
        aliasDraft = ""
        core?.hotKeys.recordingAction = nil
    }

    /// `MenuPanel`'s key hook: while an alias is being edited, every plain key belongs to its draft,
    /// ahead of the menu's own search field.
    static func handleMenuKey(_ event: NSEvent) -> Bool {
        shared.handle(event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let key = aliasKey, let core,
            event.modifierFlags.isDisjoint(with: [.command, .control])
        else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            end()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            core.aliases.setAlias(aliasDraft, for: key)
            end()
        case kVK_Delete:
            if !aliasDraft.isEmpty { aliasDraft.removeLast() }
        default:
            let printable = (event.characters ?? "").unicodeScalars.filter {
                $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
            }
            if !printable.isEmpty { aliasDraft += String(String.UnicodeScalarView(printable)) }
        }
        return true
    }
}

/// The saved alias, or the live draft with a caret while its row is being edited.
private struct MenuAliasBox: View {
    let key: String
    @Environment(\.metrics) private var metrics
    @Environment(AliasStore.self) private var aliases
    private var editor: InlineEntryEditor { .shared }

    private var editing: Bool { editor.aliasKey == key }
    private var value: String { editing ? editor.aliasDraft : (aliases.alias(for: key) ?? "") }

    var body: some View {
        HStack(spacing: 1) {
            Text(value.isEmpty ? "Add Alias" : value)
                .font(metrics.typography.keyCap)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            if editing {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Theme.Colors.textSecondary)
                    .frame(width: 1.5, height: metrics.scaled(12))
            }
        }
        .frame(width: metrics.scaled(112), height: metrics.scaled(20))
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.menuRow, style: .continuous)
                .fill(Theme.Colors.cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.radius.menuRow, style: .continuous)
                .strokeBorder(
                    editing ? Theme.Colors.textTertiary : Theme.Colors.cardStroke, lineWidth: 1))
    }

    /// Faded until the row is being edited, so it reads as settled once ↵ commits.
    private var textColor: Color {
        if value.isEmpty { return Theme.Colors.textTertiary }
        return editing ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
    }
}
