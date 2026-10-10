import AppKit
import Observation
import SwiftUI
import Synchronization

/// tinycast-space: a Raycast theme, in ray.so's format, recoloring Tinycast's own tokens.
///
/// A theme changes hues, never alphas. Every ramp token keeps the opacity Tinycast designed it with
/// and takes the theme's `text` as its ink, the selection fill takes `selection`, and the scrim over
/// the glass takes `background` — ray.so previews a theme the same way, over a blur. As in Raycast,
/// there is a light slot and a dark slot, and the appearance Tinycast draws in picks between them.
struct RaycastTheme: Codable, Hashable, Identifiable, Sendable {
    enum Appearance: String, Codable, Sendable, CaseIterable {
        case light, dark
    }

    var name: String
    var author: String
    var appearance: Appearance
    /// ray.so's order, which is also a `raycast://theme` link's: background, backgroundSecondary,
    /// text, selection, loader, red, orange, yellow, green, blue, purple, magenta.
    var colors: [String]

    var id: String { author.isEmpty ? name : "\(name) · \(author)" }

    /// The link ray.so's *Add to Raycast* opens and Raycast's Theme Studio copies; `tinycast://` too.
    init?(url: URL) {
        guard ["raycast", "tinycast"].contains(url.scheme?.lowercased() ?? ""),
            url.host()?.lowercased() == "theme",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        let colors = (value("colors") ?? "").split(separator: ",").compactMap { Self.hex6(String($0)) }
        guard let name = value("name"), !name.isEmpty, colors.count == 12,
            let appearance = value("appearance").flatMap(Appearance.init(rawValue:))
        else { return nil }
        self.init(
            name: name, author: value("author") ?? value("authorUsername") ?? "",
            appearance: appearance, colors: colors)
    }

    init(name: String, author: String, appearance: Appearance, colors: [String]) {
        self.name = name
        self.author = author
        self.appearance = appearance
        self.colors = colors
    }

    /// `#RRGGBB`. Older Theme Studio links carry an alpha pair, which ray.so drops too.
    static func hex6(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = trimmed.dropFirst()
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + digits.prefix(6).uppercased()
    }
}

/// A `raycast://theme` or `tinycast://theme` link: a theme, or Tinycast's own colors for a slot
/// (`none=light|dark`). `apply=1` — the Theme command's links — skips the dialog.
struct RaycastThemeLink: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case theme(RaycastTheme)
        case tinycast(RaycastTheme.Appearance)

        var appearance: RaycastTheme.Appearance {
            switch self {
            case .theme(let theme): theme.appearance
            case .tinycast(let slot): slot
            }
        }
    }

    let target: Target
    let applies: Bool

    init?(url: URL) {
        guard ["raycast", "tinycast"].contains(url.scheme?.lowercased() ?? ""),
            url.host()?.lowercased() == "theme"
        else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        applies = items.contains { $0.name == "apply" && $0.value == "1" }
        if let slot = items.first(where: { $0.name == "none" })?.value
            .flatMap(RaycastTheme.Appearance.init(rawValue:))
        {
            target = .tinycast(slot)
        } else if let theme = RaycastTheme(url: url) {
            target = .theme(theme)
        } else {
            return nil
        }
    }
}

/// A theme's colors, parsed once per change rather than once per draw.
struct RaycastThemePalette: Sendable {
    /// The names extensions pass for `Color.Red` and friends, in the theme's color order from red.
    static let namedColors = [
        "raycast-red", "raycast-orange", "raycast-yellow", "raycast-green", "raycast-blue",
        "raycast-purple", "raycast-magenta"
    ]

    let background: NSColor
    let backgroundSecondary: NSColor
    let text: NSColor
    let selection: NSColor
    let named: [String: NSColor]

    init(_ theme: RaycastTheme) {
        let colors = theme.colors.map(Self.color)
        func at(_ index: Int) -> NSColor { colors.indices.contains(index) ? colors[index] : .gray }
        background = at(0)
        backgroundSecondary = at(1)
        text = at(2)
        selection = at(3)
        var named = ["raycast-primary-text": at(2)]
        for (offset, name) in Self.namedColors.enumerated() { named[name] = at(5 + offset) }
        self.named = named
    }

    static func color(_ hex: String) -> NSColor {
        guard let value = UInt32(hex.dropFirst(), radix: 16) else { return .gray }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// tinycast-space: the light and dark Raycast themes. Color providers run wherever AppKit resolves
/// them, so the palettes sit behind a lock rather than on the main actor. Only AppKit and SwiftUI
/// here: the harnesses compile this file beside `Theme.swift` (`apply.sh` adds it), so switching
/// lives in `RaycastThemeSwitching.swift`.
enum SpaceTheme {
    enum Role: Sendable {
        case text, selection, background
    }

    struct Palettes: Sendable {
        var light: RaycastThemePalette?
        var dark: RaycastThemePalette?
        /// What the palette shows while an extension row offering a theme link is highlighted; a
        /// nil palette there previews Tinycast's own colors.
        var previewing = false
        var preview: RaycastThemePalette?
        var previewIsDark = false

        func callAsFunction(_ appearance: NSAppearance) -> RaycastThemePalette? {
            let isDark = appearance.isDark
            if previewing, previewIsDark == isDark { return preview }
            return isDark ? dark : light
        }

        var isEmpty: Bool { light == nil && dark == nil && preview == nil }
    }

    static let importedKey = "spaceRaycastThemesImported"
    static let opacityKey = "spaceRaycastThemeBackgroundOpacity"
    /// Above ray.so's 40 %: its preview blurs 72 px, and Tinycast's glass lets far more through.
    static let defaultOpacity = 0.7

    static func key(for slot: RaycastTheme.Appearance) -> String {
        slot == .dark ? "spaceRaycastThemeDark" : "spaceRaycastThemeLight"
    }

    /// Bumped on every palette change. Tokens read it as they are drawn, so SwiftUI redraws exactly
    /// the views showing a themed color — in place, state kept — rather than on an appearance flip.
    @Observable final class Revision: @unchecked Sendable {
        var value = 0
    }

    static let revision = Revision()

    static func observe() { _ = revision.value }

    static let state = Mutex(
        Palettes(
            light: theme(for: .light).map(RaycastThemePalette.init),
            dark: theme(for: .dark).map(RaycastThemePalette.init)))

    static func theme(for slot: RaycastTheme.Appearance) -> RaycastTheme? {
        decode(RaycastTheme.self, forKey: key(for: slot))
    }

    static var imported: [RaycastTheme] { decode([RaycastTheme].self, forKey: importedKey) ?? [] }

    static var backgroundOpacity: Double {
        UserDefaults.standard.object(forKey: opacityKey) as? Double ?? defaultOpacity
    }

    /// The theme's color for `role` at the alpha the token asks for; nil leaves Tinycast's own.
    static func ink(_ role: Role, in appearance: NSAppearance, dark: Double, light: Double) -> NSColor? {
        guard let palette = state.withLock({ $0(appearance) }) else { return nil }
        let alpha = appearance.isDark ? dark : light
        switch role {
        case .text: return palette.text.withAlphaComponent(alpha)
        case .selection: return palette.selection.withAlphaComponent(alpha)
        case .background: return palette.background.withAlphaComponent(backgroundOpacity)
        }
    }

    /// The palette's backdrop: Raycast's gradient, `background` fading into `backgroundSecondary`
    /// by 70 % of the height as ray.so draws it, or Tinycast's own scrim when there is no theme.
    static var backdrop: LinearGradient {
        observe()
        return LinearGradient(
            stops: [
                .init(color: backdropColor(\.background), location: 0),
                .init(color: backdropColor(\.backgroundSecondary), location: 0.7)
            ],
            startPoint: .top, endPoint: .bottom)
    }

    private static func backdropColor(_ keyPath: KeyPath<RaycastThemePalette, NSColor> & Sendable) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                guard let palette = state.withLock({ $0(appearance) }) else {
                    // `Theme.Colors.panelScrim`'s own values.
                    return appearance.isDark ? .srgbInk(0, alpha: 0.40) : .srgbInk(1, alpha: 0.55)
                }
                return palette[keyPath: keyPath].withAlphaComponent(backgroundOpacity)
            })
    }

    /// Floating glass — menus, the action capsule — tinted with the theme's background.
    static func tinted(_ glass: Glass) -> Glass {
        observe()
        return state.withLock { $0.isEmpty } ? glass : glass.tint(glassTint)
    }

    private static var glassTint: Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                state.withLock { $0(appearance) }?.background.withAlphaComponent(backgroundOpacity)
                    ?? .clear
            })
    }

    /// An extension's named color, following whichever slot the surface is drawn in.
    static func namedColor(_ name: String, fallback: Color?) -> Color? {
        guard name.hasPrefix("raycast-"), !state.withLock({ $0.isEmpty }) else {
            return nil
        }
        let base = fallback.map { NSColor($0) }
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                state.withLock { $0(appearance)?.named[name] } ?? base ?? .labelColor
            })
    }

    static func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    static func encode<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            return UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}
