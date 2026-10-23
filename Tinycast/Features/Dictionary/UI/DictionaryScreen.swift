import SwiftUI

/// The search field is the term; the entry fills the palette instead of competing with a list.
struct DictionaryScreen: PaletteScreen {
    let session: DictionarySession
    let core: AppCore
    let vm: PaletteState

    private var term: String { vm.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The page on screen: it stays up while the next term resolves, and ↵ acts on what is shown.
    private var entry: DictionaryEntry? { session.lookup?.entry }

    /// The one entry, or the spellings offered in its place, so the footer and ⌘K act on the
    /// selection exactly as on a row.
    var rows: [DictionaryResult] {
        if let entry { return [.definition(entry)] }
        return (session.lookup?.suggestions ?? []).map(DictionaryResult.suggestion)
    }

    var primaryActionTitle: String {
        entry == nil ? String(localized: "Look Up") : String(localized: "Copy Definition")
    }

    private func result(at selection: Int) -> DictionaryResult? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let result = result(at: selection) else { return nil }
        var items = [
            PopoverMenuItem(
                title: primaryActionTitle,
                systemImage: entry == nil ? "text.magnifyingglass" : "doc.on.doc", shortcut: "↵"
            ) {
                activate(result)
            }
        ]
        if case .suggestion(let word) = result {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Copy"), systemImage: "doc.on.doc", shortcut: "⌥↵"
                ) {
                    core.dictionaryCoordinator.copyWord(word)
                })
        }
        items.append(
            PopoverMenuItem(
                title: String(localized: "Open in Dictionary"), systemImage: "book", shortcut: "⌘↵"
            ) {
                core.dictionaryCoordinator.openInDictionary(result.id)
            })
        return PopoverMenuContent(header: result.id, items: items)
    }

    func activate(at selection: Int) {
        guard let result = result(at: selection) else { return }
        activate(result)
    }

    private func activate(_ result: DictionaryResult) {
        switch result {
        case .definition(let entry): core.dictionaryCoordinator.copy(entry)
        case .suggestion(let word): vm.rewriteQuery(word)
        }
    }

    func secondary(at selection: Int) -> Bool {
        guard let result = result(at: selection) else { return false }
        core.dictionaryCoordinator.openInDictionary(result.id)
        return true
    }

    /// ⌥↵ copies a suggested word; a shown definition has only ↵ to copy.
    func pasteKeepingWindowOpen(at selection: Int) -> Bool {
        guard case .suggestion(let word)? = result(at: selection) else { return false }
        core.dictionaryCoordinator.copyWord(word)
        return true
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        if term.isEmpty { return AnyView(EmptyResults(text: String(localized: "Type a word to define"))) }
        if let entry { return AnyView(DictionaryEntryView(entry: entry)) }
        if !rows.isEmpty {
            return AnyView(
                DictionarySuggestionsView(
                    words: rows.map(\.id), selection: selection, scroll: scroll,
                    onActivate: { activate(.suggestion($0)) }))
        }
        if session.lookup?.term == term {
            return AnyView(EmptyResults(text: String(localized: "No definition found")))
        }
        return AnyView(Color.clear)
    }
}
