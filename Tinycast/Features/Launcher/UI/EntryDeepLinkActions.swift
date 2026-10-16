import Foundation

/// tinycast-space: opens an entry's `tinycast://open` link and offers its "Copy Deeplink" row.
@MainActor
enum EntryDeepLinkActions {
    /// Claims `tinycast://open` links. Always true for one, so a stale id never falls through to
    /// the extension router and opens the launcher.
    static func handle(_ url: URL, in core: AppCore) -> Bool {
        guard url.scheme?.lowercased() == EntryDeepLink.scheme,
            url.host?.lowercased() == EntryDeepLink.host
        else { return false }
        guard let id = EntryDeepLink.entryID(from: url),
            let entry = core.appIndex.apps.first(where: { $0.id == id }),
            isLinkable(entry)
        else {
            core.showMessage("No launcher entry for this link", tone: .danger)
            return true
        }
        // A snippet pastes where the caret is, which a hidden palette must work out itself.
        if entry.kind == .snippet, let snippetID = StoredSnippet.id(fromEntryID: entry.id) {
            core.snippetCoordinator.expandSnippetFromHotKey(id: snippetID)
        } else {
            core.launcherCoordinator.launch(entry)
        }
        return true
    }

    /// Query-driven rows answer typed text and meetings are today's events; neither has a stable link.
    static func isLinkable(_ entry: AppEntry) -> Bool {
        entry.kind != .meeting && !CommandCatalog.isQueryDriven(entry)
    }

    static func link(for entry: AppEntry, core: AppCore) -> URL? {
        guard isLinkable(entry) else { return nil }
        if entry.kind == .extensionCommand {
            guard let (owner, command) = core.extensions.resolve(entry) else { return nil }
            return EntryDeepLink.extensionURL(
                owner: owner.manifest.storeHandle, slug: owner.manifest.name, command: command.name)
        }
        return EntryDeepLink.url(forEntryID: entry.id)
    }

    static func menuItems(for entry: AppEntry, core: AppCore) -> [PopoverMenuItem] {
        guard let url = link(for: entry, core: core) else { return [] }
        return [
            PopoverMenuItem(title: "Copy Deeplink", systemImage: "link") {
                core.paletteCoordinator.hidePalette(restoreFocus: false)
                core.showMessage(
                    Paster.copyPlainText(url.absoluteString)
                        ? "Deeplink copied" : "Couldn’t copy deeplink")
            }
        ]
    }
}
