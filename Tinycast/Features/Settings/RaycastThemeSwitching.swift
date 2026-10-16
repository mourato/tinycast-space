import AppKit
import SwiftUI

/// tinycast-space: putting a Raycast theme in its slot, previewing one on the palette, and
/// repainting what is already on screen.
extension SpaceTheme {
    /// At launch: the Theme command's extension.
    @MainActor static func start() {
        RaycastThemeCommand.install()
    }

    /// `nil` empties the slot, handing that appearance back to Tinycast's own colors.
    @MainActor static func select(_ theme: RaycastTheme?, for slot: RaycastTheme.Appearance) {
        encode(theme, forKey: key(for: slot))
        let palette = theme.map(RaycastThemePalette.init)
        state.withLock {
            if slot == .dark { $0.dark = palette } else { $0.light = palette }
        }
        RaycastThemeCommand.publish()
        repaint()
    }

    /// Kept in the imported list, newest first, without touching either slot.
    @MainActor static func add(_ theme: RaycastTheme) {
        encode([theme] + imported.filter { $0.id != theme.id }, forKey: importedKey)
        RaycastThemeCommand.publish()
    }

    /// A theme from a link: kept in the imported list and put in its slot.
    @MainActor static func install(_ theme: RaycastTheme) {
        add(theme)
        select(theme, for: theme.appearance)
    }

    @MainActor static func remove(_ theme: RaycastTheme) {
        encode(imported.filter { $0.id != theme.id }, forKey: importedKey)
        RaycastThemeCommand.publish()
        if self.theme(for: theme.appearance)?.id == theme.id { select(nil, for: theme.appearance) }
    }

    /// A theme link from anywhere. The Theme command's own links apply at once; any other asks.
    @MainActor static func handle(_ url: URL, in core: AppCore) -> Bool {
        guard let link = RaycastThemeLink(url: url) else { return false }
        let slot = link.target.appearance.rawValue
        switch (link.target, link.applies) {
        case (.tinycast(let appearance), _):
            select(nil, for: appearance)
            core.showMessage("\(slot.capitalized) theme: Tinycast")
        case (.theme(let theme), true):
            install(theme)
            core.showMessage("\(slot.capitalized) theme: \(theme.name)")
        case (.theme(let theme), false):
            offer(theme, in: core)
        }
        return true
    }

    /// A link asks before it changes anything; the palette stays open behind the dialog.
    @MainActor private static func offer(_ theme: RaycastTheme, in core: AppCore) {
        let slot = theme.appearance.rawValue
        Task {
            let choice = await core.choose(
                title: "Use “\(theme.name)” as your \(slot) theme?",
                message: "Just Add keeps it for the Theme command and Settings → General.",
                symbol: "paintpalette",
                options: [
                    DialogAction(title: "Use Theme"),
                    DialogAction(title: "Just Add"),
                    DialogAction(title: "Cancel", role: .cancel)
                ],
                defaultIndex: 0)
            switch choice {
            case 0:
                install(theme)
                core.showMessage("\(slot.capitalized) theme: \(theme.name)")
            case 1:
                add(theme)
                core.showMessage("Added \(theme.name)")
            default:
                break
            }
        }
    }

    // MARK: - Previewing on the palette

    @MainActor private static var previewed: (target: RaycastThemeLink.Target, window: NSWindow)?

    /// Shows `target` on `window` alone, appearance included, until it is asked for `nil`.
    @MainActor static func preview(_ target: RaycastThemeLink.Target?, in window: NSWindow?) {
        let next: (target: RaycastThemeLink.Target, window: NSWindow)? =
            target.flatMap { target in window.map { (target: target, window: $0) } }
        guard next?.target != previewed?.target || next?.window !== previewed?.window else { return }
        let ending = previewed?.window
        previewed = next
        state.withLock {
            $0.previewing = next != nil
            if case .theme(let theme) = next?.target {
                $0.preview = RaycastThemePalette(theme)
            } else {
                $0.preview = nil
            }
            $0.previewIsDark = next?.target.appearance == .dark
        }
        // Only a light/dark the window doesn't already have is a real switch; the hue is a redraw.
        if let ending, ending !== next?.window { ending.appearance = nil }
        if let next {
            next.window.appearance = NSAppearance(
                named: next.target.appearance == .dark ? .darkAqua : .aqua)
        }
        repaint()
    }

    /// Every view drawing a themed color redraws in place, hidden ones as they next appear.
    @MainActor static func repaint() {
        revision.value += 1
    }
}

/// tinycast-space: previews the theme an extension row offers — Raycast Explorer's *Add to
/// Raycast* is an `Action.Open` on a `raycast://theme` link — on the palette while it is highlighted.
struct RaycastThemeLinkPreview: ViewModifier {
    let screen: ExtensionScreen
    let selection: Int

    func body(content: Content) -> some View {
        content
            .onChange(of: target(at: selection), initial: true) { _, target in
                SpaceTheme.preview(target, in: NSApp.keyWindow)
            }
            .onDisappear { SpaceTheme.preview(nil, in: nil) }
    }

    private func target(at index: Int) -> RaycastThemeLink.Target? {
        screen.actionPanel(forItemAt: index).flatMap(Self.themeLink)?.target
    }

    private static func themeLink(in node: RenderNode) -> RaycastThemeLink? {
        if let target = node.props["target"]?.stringValue, let url = URL(string: target),
            let link = RaycastThemeLink(url: url)
        {
            return link
        }
        return node.children.lazy.compactMap(themeLink).first
    }
}
