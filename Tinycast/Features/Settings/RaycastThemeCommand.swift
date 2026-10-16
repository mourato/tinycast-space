import AppKit

/// tinycast-space: the Theme command — a small extension Tinycast writes into its own extensions
/// folder, so picking a theme needs no new palette mode. Its rows offer `tinycast://theme` links,
/// so the palette previews each one as it is highlighted (`RaycastThemeLinkPreview`), and their
/// `apply=1` makes ↵ switch at once. The installed themes reach it as `assets/themes.json`.
enum RaycastThemeCommand {
    static let folderName = "tinycast-space-themes"

    private static var folder: URL {
        ExtensionCatalog.extensionsDirectory().appendingPathComponent(folderName, isDirectory: true)
    }

    /// Writes the extension when it is missing or older than this build's, then the theme list.
    @MainActor static func install() {
        let fm = FileManager.default
        let assets = folder.appendingPathComponent("assets", isDirectory: true)
        try? fm.createDirectory(at: assets, withIntermediateDirectories: true)
        write(manifest, to: folder.appendingPathComponent("package.json"))
        write(script, to: folder.appendingPathComponent("theme.js"))
        let icon = assets.appendingPathComponent("icon.png")
        if !fm.fileExists(atPath: icon.path), let png = renderIcon() { try? png.write(to: icon) }
        publish()
    }

    /// The installed themes and what each slot holds, for the command to list.
    @MainActor static func publish() {
        let slots = RaycastTheme.Appearance.allCases.map { SpaceTheme.theme(for: $0) }.compactMap { $0 }
        var themes = SpaceTheme.imported
        for theme in slots where !themes.contains(where: { $0.id == theme.id }) { themes.append(theme) }
        let payload: [String: Any] = [
            "light": SpaceTheme.theme(for: .light)?.id as Any,
            "dark": SpaceTheme.theme(for: .dark)?.id as Any,
            "themes": themes.map {
                [
                    "name": $0.name, "author": $0.author, "appearance": $0.appearance.rawValue,
                    "colors": $0.colors
                ]
            }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        let url = folder.appendingPathComponent("assets/themes.json")
        guard (try? Data(contentsOf: url)) != data else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func write(_ text: String, to url: URL) {
        let data = Data(text.utf8)
        guard (try? Data(contentsOf: url)) != data else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func renderIcon() -> Data? {
        let side: CGFloat = 128
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 28, yRadius: 28)
            NSGradient(
                colors: [
                    NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1),
                    NSColor(srgbRed: 0.93, green: 0.36, blue: 0.62, alpha: 1)
                ])?
                .draw(in: tile, angle: -60)
            let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            guard
                let symbol = NSImage(systemSymbolName: "paintpalette.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)
            else { return true }
            let size = symbol.size
            symbol.draw(in: NSRect(
                x: (side - size.width) / 2, y: (side - size.height) / 2,
                width: size.width, height: size.height))
            return true
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private static let manifest = """
        {
          "name": "tinycast-space-themes",
          "title": "Themes",
          "description": "Switch between your installed Raycast themes. Part of Tinycast Space Edition.",
          "icon": "icon.png",
          "author": "tinycast-space",
          "categories": ["System"],
          "license": "AGPL-3.0",
          "platforms": ["macOS"],
          "commands": [
            {
              "name": "theme",
              "title": "Theme",
              "subtitle": "Themes",
              "description": "Pick a light or dark theme; the window previews each one as you move.",
              "mode": "view"
            }
          ]
        }

        """

    private static let script = """
        "use strict";
        // Written by Tinycast Space Edition (RaycastThemeCommand.swift) on every launch; edits are lost.
        Object.defineProperty(exports, "__esModule", { value: true });
        const { List, ActionPanel, Action, Icon, environment, closeMainWindow } = require("@raycast/api");
        const { jsx } = require("react/jsx-runtime");
        const fs = require("fs");
        const path = require("path");

        function load() {
          const files = [
            path.join(environment.assetsPath || "", "themes.json"),
            path.join(__dirname, "assets", "themes.json"),
          ];
          for (const file of files) {
            try {
              return JSON.parse(fs.readFileSync(file, "utf8"));
            } catch {}
          }
          return { light: null, dark: null, themes: [] };
        }

        const q = encodeURIComponent;
        const capital = (s) => s[0].toUpperCase() + s.slice(1);
        const themeID = (t) => (t.author ? `${t.name} · ${t.author}` : t.name);
        const link = (t) =>
          `tinycast://theme?apply=1&version=1&name=${q(t.name)}&author=${q(t.author)}` +
          `&appearance=${t.appearance}&colors=${t.colors.map(q).join(",")}`;
        const swatch = (t) =>
          "data:image/svg+xml," +
          q(
            `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><defs>` +
              `<linearGradient id="g" x1="0" x2="0" y1="0" y2="1">` +
              `<stop offset="0%" stop-color="${t.colors[0]}"/>` +
              `<stop offset="100%" stop-color="${t.colors[1]}"/></linearGradient></defs>` +
              `<circle cx="12" cy="12" r="10" fill="url(#g)"` +
              ` stroke="${t.colors[2]}" stroke-opacity="0.35"/>` +
              `<circle cx="12" cy="12" r="3.5" fill="${t.colors[3]}"/></svg>`,
          );

        function row(slot, current, theme) {
          const id = theme ? themeID(theme) : null;
          const inUse = current === id;
          return jsx(
            List.Item,
            {
              id: `${slot}:${id ?? "tinycast"}`,
              title: theme ? theme.name : "Tinycast",
              subtitle: theme ? theme.author : "No theme",
              icon: theme ? swatch(theme) : Icon.Circle,
              keywords: [slot, ...(theme ? [theme.author] : [])],
              accessories: inUse ? [{ icon: Icon.Checkmark, tooltip: "In use" }] : [],
              actions: jsx(ActionPanel, {
                children: jsx(Action.Open, {
                  title: `Use as ${capital(slot)} Theme`,
                  icon: Icon.Brush,
                  target: theme ? link(theme) : `tinycast://theme?apply=1&none=${slot}`,
                  onOpen: () => closeMainWindow(),
                }),
              }),
            },
            `${slot}:${id ?? "tinycast"}`,
          );
        }

        function Command() {
          const data = load();
          const now = environment.appearance === "dark" ? "dark" : "light";
          const slots = now === "dark" ? ["dark", "light"] : ["light", "dark"];
          return jsx(List, {
            searchBarPlaceholder: "Search installed themes",
            selectedItemId: `${now}:${data[now] ?? "tinycast"}`,
            // Tinycast seeds selectedItemId only for a list that also reports selection changes.
            onSelectionChange: () => {},
            children: slots.map((slot) =>
              jsx(
                List.Section,
                {
                  title: `${capital(slot)} Themes`,
                  children: [null, ...data.themes.filter((t) => t.appearance === slot)].map((theme) =>
                    row(slot, data[slot] ?? null, theme),
                  ),
                },
                slot,
              ),
            ),
          });
        }

        exports.default = Command;

        """
}
