import SwiftUI

// tinycast-space: the launcher's `?` scope searches Tinycast's own Settings.
/// A leading `?` turns root search into a search over Settings; the mode stays launcher, so Esc,
/// history and the footer keep working.
struct SettingsSearchScreen: PaletteScreen {
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    /// What follows a leading `?`, or nil when the query is not scoped to settings.
    static func scope(of query: String) -> String? {
        guard query.first == "?" else { return nil }
        return String(query.dropFirst())
    }

    var rows: [SettingsSearchEntry] {
        SettingsSearchCatalog.scopeResults(for: Self.scope(of: vm.query) ?? "")
    }

    var primaryActionTitle: String { String(localized: "Open in Settings") }

    private func entry(at selection: Int) -> SettingsSearchEntry? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func hasActions(at selection: Int) -> Bool { false }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        guard case .favoriteSlot(let index) = shortcut else { return false }
        let rows = rows
        guard index < LauncherList.numberedResultLimit, rows.indices.contains(index) else {
            return false
        }
        open(rows[index])
        return true
    }

    func activate(at selection: Int) {
        guard let entry = entry(at: selection) else { return }
        open(entry)
    }

    /// One row opens one place.
    func secondary(at selection: Int) -> Bool { false }

    private func open(_ entry: SettingsSearchEntry) {
        core.paletteCoordinator.hidePalette(restoreFocus: false)
        core.settingsCoordinator.showSettings(tab: entry.tab, revealing: entry.target)
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        let rows = rows
        guard !rows.isEmpty else {
            return AnyView(EmptyResults(text: String(localized: "No results")))
        }
        let selectedID = rows.indices.contains(selection) ? rows[selection].id : nil
        return AnyView(
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { offset, entry in
                            SettingsSearchScreenRow(
                                entry: entry, selected: entry.id == selectedID,
                                slot: offset < LauncherList.numberedResultLimit
                                    ? FavoriteSlots.digit(at: offset) : nil
                            )
                            .selectionFrame(entry.id == selectedID)
                            .contentShape(Rectangle())
                            .onRowClick(
                                select: { vm.selection = offset },
                                activate: { open(entry) })
                        }
                    }
                    .padding(.horizontal, metrics.spacing.md)
                    .padding(.top, metrics.spacing.xs)
                    .padding(.bottom, metrics.spacing.md)
                    .hideNativeScrollers()
                    .scrollOriginAnchor()
                }
                .edgeDissolve()
                .thinScrollbar()
                .scrollFollowsSelection(
                    scroll, row: selectedID, atOrigin: selection == 0, proxy: proxy)
            }
        )
    }

    private var metrics: InterfaceMetrics { core.settings.interfaceSize.metrics }
}

private struct SettingsSearchScreenRow: View {
    @Environment(\.metrics) private var metrics
    let entry: SettingsSearchEntry
    let selected: Bool
    /// This row's ⌘-digit, or nil past the ninth.
    let slot: Character?
    @Environment(PaletteState.self) private var palette
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            SettingsTabIcon(
                systemImage: entry.tab.systemImage, tint: .accentColor,
                size: metrics.size.resultRowIcon)
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(entry.title)
                    .font(metrics.typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.breadcrumb)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let slot, palette.commandHeld {
                HStack(spacing: metrics.spacing.xxs) {
                    KeyCapChip(text: "⌘", style: .outline)
                    KeyCapChip(text: String(slot), style: .outline)
                }
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                .fill(fill)
        )
        .armedHover($hovered)
    }
}
