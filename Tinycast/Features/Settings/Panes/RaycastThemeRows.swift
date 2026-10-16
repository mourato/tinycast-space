import SwiftUI

/// tinycast-space: Settings → General → Appearance rows for Raycast themes — a light and a dark
/// slot, as in Raycast, each chosen in a browser that previews whatever the pointer rests on.
struct RaycastThemeRows: View {
    @State private var light = SpaceTheme.theme(for: .light)
    @State private var dark = SpaceTheme.theme(for: .dark)
    @State private var imported = SpaceTheme.imported
    @State private var importNote: String?
    @AppStorage(SpaceTheme.opacityKey) private var opacity = SpaceTheme.defaultOpacity

    private static let gallery = URL(string: "https://www.ray.so/themes")!

    var body: some View {
        RaycastThemeSlotRow(slot: .light, selected: $light, imported: $imported, opacity: opacity)
        RaycastThemeSlotRow(slot: .dark, selected: $dark, imported: $imported, opacity: opacity)

        if light != nil || dark != nil {
            LabeledContent {
                Slider(value: $opacity, in: 0.2...1) { editing in
                    if !editing { SpaceTheme.repaint() }
                }
                .frame(maxWidth: 220)
            } label: {
                SettingsRowTitle(.generalAppearance, "Theme background")
                Text("How much of the glass the theme's background covers.")
            }
        }

        HStack {
            Button("Import Link from Clipboard", action: importFromClipboard)
                .help("Paste a raycast://theme link from ray.so or Raycast's Theme Studio.")
            Link("Browse Themes", destination: Self.gallery)
            Spacer()
            if let importNote {
                Text(importNote).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    private func importFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let theme = text.flatMap(URL.init(string:)).flatMap(RaycastTheme.init(url:)) else {
            importNote = "No theme link on the clipboard."
            return
        }
        SpaceTheme.install(theme)
        imported = SpaceTheme.imported
        if theme.appearance == .dark { dark = theme } else { light = theme }
        importNote = "\(theme.name) is now the \(theme.appearance.rawValue) theme."
    }
}

/// One slot: the chosen theme's swatch and name, opening the browser.
private struct RaycastThemeSlotRow: View {
    let slot: RaycastTheme.Appearance
    @Binding var selected: RaycastTheme?
    @Binding var imported: [RaycastTheme]
    let opacity: Double
    @State private var browsing = false

    var body: some View {
        LabeledContent {
            Button {
                browsing = true
            } label: {
                HStack(spacing: 6) {
                    RaycastThemeSwatch(theme: selected, slot: slot)
                    Text(selected?.name ?? "Tinycast")
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            .popover(isPresented: $browsing, arrowEdge: .trailing) {
                RaycastThemeBrowser(
                    slot: slot, selected: $selected, imported: $imported, opacity: opacity,
                    dismiss: { browsing = false })
            }
        } label: {
            if slot == .dark {
                SettingsRowTitle(.generalAppearance, "Dark theme")
                Text("While Tinycast is dark.")
            } else {
                SettingsRowTitle(.generalAppearance, "Light theme")
                Text("While Tinycast is light.")
            }
        }
    }
}

/// The slot's themes under a live preview of the hovered one, or of the chosen one at rest.
private struct RaycastThemeBrowser: View {
    let slot: RaycastTheme.Appearance
    @Binding var selected: RaycastTheme?
    @Binding var imported: [RaycastTheme]
    let opacity: Double
    let dismiss: () -> Void

    /// Hovering Tinycast's own row previews no theme, which `nil` alone can't tell from no hover.
    private enum Hover: Equatable {
        case tinycast
        case theme(RaycastTheme)
    }

    @State private var hover: Hover?
    @State private var query = ""

    private var previewed: RaycastTheme? {
        switch hover {
        case .none: selected
        case .tinycast: nil
        case .theme(let theme): theme
        }
    }

    private func matching(_ themes: [RaycastTheme]) -> [RaycastTheme] {
        themes.filter {
            $0.appearance == slot
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.author.localizedCaseInsensitiveContains(query))
        }
    }

    private var mine: [RaycastTheme] { matching(imported) }

    /// An imported copy of a bundled theme replaces it, so no theme is listed twice.
    private var bundled: [RaycastTheme] {
        let importedIDs = Set(imported.map(\.id))
        return matching(RaycastThemeCatalog.all).filter { !importedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RaycastThemePreview(theme: previewed, slot: slot, opacity: opacity)
            TextField("Search \(slot.rawValue) themes", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if query.isEmpty {
                        row(nil, title: "Tinycast", subtitle: "No theme", hoverKey: .tinycast)
                    }
                    section("Imported", mine)
                    section("ray.so", bundled)
                }
            }
            .frame(height: 260)
            .onHover { inside in if !inside { hover = nil } }
        }
        .padding(12)
        .frame(width: 400)
    }

    @ViewBuilder
    private func section(_ title: String, _ themes: [RaycastTheme]) -> some View {
        if !themes.isEmpty {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            ForEach(themes) { theme in
                row(theme, title: theme.name, subtitle: theme.author, hoverKey: .theme(theme))
                    .contextMenu {
                        if imported.contains(theme) {
                            Button("Remove Imported Theme") {
                                SpaceTheme.remove(theme)
                                imported = SpaceTheme.imported
                                selected = SpaceTheme.theme(for: slot)
                            }
                        }
                    }
            }
        }
    }

    private func row(_ theme: RaycastTheme?, title: String, subtitle: String, hoverKey: Hover) -> some View {
        HStack(spacing: 8) {
            RaycastThemeSwatch(theme: theme, slot: slot)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Spacer()
            if theme?.id == selected?.id {
                Image(systemName: "checkmark").foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            hover == hoverKey ? Theme.Colors.rowHover : .clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { inside in if inside { hover = hoverKey } }
        .onTapGesture {
            SpaceTheme.select(theme, for: slot)
            selected = theme
            dismiss()
        }
    }
}

/// A theme at a glance: its background, with its text and selection colors on it.
private struct RaycastThemeSwatch: View {
    let theme: RaycastTheme?
    let slot: RaycastTheme.Appearance

    var body: some View {
        let colors = RaycastThemePreview.Colors(theme: theme, slot: slot, opacity: 1)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(colors.background)
            .overlay {
                HStack(spacing: 2) {
                    Circle().fill(colors.ink(1)).frame(width: 5, height: 5)
                    Circle().fill(colors.selection(1)).frame(width: 5, height: 5)
                    Circle().fill(colors.accent(9, .blue)).frame(width: 5, height: 5)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.Colors.cardStroke)
            }
            .frame(width: 28, height: 18)
    }
}

/// A small launcher drawn with a theme's colors at the alphas Tinycast's own tokens use.
private struct RaycastThemePreview: View {
    let theme: RaycastTheme?
    let slot: RaycastTheme.Appearance
    let opacity: Double

    struct Colors {
        let theme: RaycastTheme?
        let slot: RaycastTheme.Appearance
        let opacity: Double

        var isDark: Bool { slot == .dark }

        private func color(_ index: Int) -> Color? {
            guard let theme, theme.colors.indices.contains(index) else { return nil }
            return Color(nsColor: RaycastThemePalette.color(theme.colors[index]))
        }

        func ink(_ alpha: Double) -> Color { (color(2) ?? (isDark ? .white : .black)).opacity(alpha) }

        func selection(_ alpha: Double) -> Color { color(3)?.opacity(alpha) ?? ink(alpha) }

        func accent(_ index: Int, _ fallback: Color) -> Color { color(index) ?? fallback }

        /// Tinycast's own scrim when there is no theme, as `Theme.Colors.panelScrim` draws it.
        var background: Color {
            color(0)?.opacity(opacity) ?? (isDark ? Color.black.opacity(0.40) : Color.white.opacity(0.55))
        }

        /// `SpaceTheme.backdrop` for this one theme: the gradient Raycast draws.
        var backdrop: LinearGradient {
            LinearGradient(
                stops: [
                    .init(color: background, location: 0),
                    .init(color: color(1)?.opacity(opacity) ?? background, location: 0.7)
                ],
                startPoint: .top, endPoint: .bottom)
        }
    }

    var body: some View {
        let colors = Colors(theme: theme, slot: slot, opacity: opacity)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(colors.ink(0.6))
                Text("Search for apps and commands…").foregroundStyle(colors.ink(0.4))
                Spacer()
            }
            .font(.system(size: 14))
            .padding(.horizontal, 14)
            .frame(height: 40)
            Rectangle().fill(colors.ink(colors.isDark ? 0.10 : 0.12)).frame(height: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text("Suggestions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(colors.ink(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                previewRow(colors, "Clipboard History", "Command", "doc.on.clipboard", 9, .blue, true)
                previewRow(colors, "Calendar", "Command", "calendar", 5, .red, false)
                previewRow(colors, "Search Files", "Command", "folder", 8, .green, false)
                previewRow(colors, "Start Timer", "Timers", "timer", 6, .orange, false)
            }
            .padding(6)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Spacer()
                Text("Open Command").foregroundStyle(colors.ink(1))
                Text("↵")
                    .foregroundStyle(colors.ink(0.6))
                    .padding(.horizontal, 5)
                    .background(
                        colors.ink(colors.isDark ? 0.10 : 0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .frame(height: 236)
        .background(colors.backdrop)
        .background(PreviewGlass(isDark: colors.isDark))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, colors.isDark ? .dark : .light)
        .animation(.easeOut(duration: 0.12), value: theme)
    }

    // swiftlint:disable:next function_parameter_count
    private func previewRow(
        _ colors: Colors, _ title: String, _ kind: String, _ symbol: String, _ tint: Int,
        _ fallback: Color, _ selected: Bool
    ) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(colors.accent(tint, fallback))
                .overlay { Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.white) }
                .frame(width: 20, height: 20)
            Text(title).foregroundStyle(colors.ink(1))
            Spacer()
            Text(kind).foregroundStyle(colors.ink(colors.isDark ? 0.40 : 0.42))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            selected ? colors.selection(colors.isDark ? 0.10 : 0.09) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The palette's glass, pinned to the previewed slot's appearance whatever Settings is drawn in.
private struct PreviewGlass: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> NSGlassEffectView { NSGlassEffectView() }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}
