# ✨ Tinycast Space Edition

**Tinycast Space Edition** is an unofficial, automatically synced fork of **[Tinycast](https://github.com/abue-ammar/tinycast)** by
[Abue Ammar](https://github.com/abue-ammar), with a few small patches on top.

Everything that makes Tinycast good is the original author's work. This fork only carries the handful
of changes listed below. For what Tinycast is and how to use it, read the
**[original README](README.upstream.md)**, which is kept verbatim.

## What's different in this fork

| Change | Why |
| --- | --- |
| **Alias + Space.** Type an alias exactly and press Space: a command with inline arguments jumps into its first field, a search command whose arguments are all optional opens so you type straight into its own search (`brew` → Search Homebrew), anything else opens, so you keep typing inside it, the way Raycast does. Apps and settings panes keep searching. See [Alias + Space](#alias--space) for the rules. | Muscle memory from Raycast. Declined upstream ([#696](https://github.com/abue-ammar/tinycast/issues/696), [#908](https://github.com/abue-ammar/tinycast/issues/908)). |
| **Updates come from this fork.** The in-app updater and the About link point here. | So an installed fork build is never replaced by an upstream build without the patches. |
| **Extension runtime fixes.** `querystring.stringify` coerces `undefined` to `""` and `require("buffer")` exposes `Blob` and `File`, both as Node does; a bundled undici sends its requests through Tinycast's own `fetch` instead of sockets. | Without them, Google sign-in in extensions such as 2FA Code Finder fails with `invalid_client`, and extensions bundling undici (Google Translate) crash on load or fail with `net.isIP` is not supported. |
| **Edit aliases and shortcuts from ⌘K.** Every launcher entry's ⌘K menu has *Change Alias* and *Change Shortcut* rows that edit in place, extension commands included. | Faster than a trip to Settings. Ported, with thanks, from [jhasubhash/tinycast](https://github.com/jhasubhash/tinycast). |
| **Confetti.** Raycast's celebration: a *Confetti* command among the system actions, and `raycast://confetti` / `tinycast://confetti`, which is what extensions fire when a timer or task finishes. Every parameter is a `confetti.*` default, so it can be retuned without a rebuild. | Extensions call that link; upstream Tinycast ignores it. |
| **Show every copy of an app.** Settings → Applications → Search Scopes → *Show every copy of an app* lists every app bundle, as Spotlight does, even when two share a bundle ID. | Upstream keeps only the first copy, so a utility that borrows App Store's bundle ID (such as Stop The Mac App Store) hides the real App Store, and a second Xcode folds into the first. |
| **Raycast themes.** Settings → General → Appearance → *Light theme* / *Dark theme*, switched with the appearance like in Raycast, including Raycast's background gradient. Pick from ray.so's community themes with a live preview on hover, or from your installed ones with the *Theme* command, where the window takes each theme as you move through the list. In the Raycast Explorer extension the highlighted theme previews the same way, and *Add to Raycast* asks whether to use it. Your own themes come in as `raycast://theme` links from ray.so or Raycast's Theme Studio (*Import Link from Clipboard*). | Upstream declined themes ([#640](https://github.com/abue-ammar/tinycast/issues/640)). The themes are their authors', via [raycast/ray-so](https://github.com/raycast/ray-so) (MIT). |
| **Extension sign-in kept.** Extensions that sign in through Raycast's OAuth — Spotify Player, Gmail, Trakt Manager and the like — keep working. | Upstream removed extension OAuth ([#1445](https://github.com/abue-ammar/tinycast/pull/1445)); without it those extensions can't authenticate. |
| **Hyper glyph for external remappers.** With Hyper Key set to None, *Show ✦ for another app's Hyper key* still shows ✦ for the Hyper chord. | For Hyper keys provided by Karabiner, Hyperkey and similar apps. |

## Alias + Space

- **Only an exact, case-sensitive match jumps in.** With `cc` as the alias of *Change Case*, `cc` + Space
  opens it, while `CC` + Space (Shift held) or `Cc` + Space just keeps searching. It works the other way
  round too: give a command an alias like `CC`, and lowercase typing never jumps into it. Search and
  ranking stay case-insensitive; only the jump cares about case.
- **`\` + Space escapes the jump.** Type a backslash right before the Space and it becomes a plain space:
  `cc\` + Space turns into `cc ` and searches for everything starting with "cc".
- Apps and System Settings panes never jump: `tg something` searches rather than launching Telegram.

Each change is a small patch in [`.space/patches`](.space/patches); [`.space/README.md`](.space/README.md)
explains how the fork is built.

## How it stays in sync

- **Every upstream commit** lands here within about 10–30 minutes: `main` is rebuilt as *upstream main +
  the patches*, then built and tested with upstream's own test suite before anything is pushed.
- **Every upstream stable release** is re-released here under the same version number, with the
  patches applied. Installed copies of this fork update themselves from these releases.
- If a patch stops applying or breaks the build, nothing is published: the fork simply stays on the
  last good version until the patch is fixed.

The fork never publishes a version number of its own, so it can't get ahead of, or conflict with,
upstream's releases.

## Install

1. Download `Tinycast-<version>.dmg` from this fork's
   **[Releases](https://github.com/sermelipharo/tinycast-space/releases)** and drag Tinycast to
   Applications.
2. The build is self-signed with this fork's own certificate (it is not notarized), so clear the
   quarantine flag once:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Tinycast.app"
   ```
3. Open Tinycast and grant Accessibility when asked (System Settings → Privacy & Security →
   Accessibility).

Good to know:

- **It replaces the original, it does not sit beside it.** The fork keeps upstream's bundle ID
  (`com.tinycast.app`), so your settings, aliases, snippets and extensions carry over in both
  directions. Quit the original before installing.
- **Coming from the original, re-grant Accessibility once.** macOS ties the grant to the signing
  certificate, and this fork signs with a different one. Remove the old Tinycast entry from the
  Accessibility list and add the new app.
- **There is no Homebrew cask for the fork.** `brew install --cask tinycast` installs the original.
  If you have it through Homebrew, `brew uninstall --cask tinycast` first; the fork updates itself.
- **Going back to the original** is the same move in reverse: install it from
  [upstream](https://github.com/abue-ammar/tinycast#install) and re-grant Accessibility.
- Apple silicon only; there is no universal (Intel) build of the fork.

## Respect for the original project

Tinycast is Abue Ammar's project, and its direction is his call. The features added here were
declined upstream on purpose, to keep Tinycast small and focused. That is a fair decision, and this
fork is not a protest against it. It exists only because the AGPL lets people keep a small variant
for themselves, and it stays as close to upstream as possible.

So please:

- **Don't take fork-only behavior upstream.** No issues, pull requests or Discord messages asking the
  maintainer to adopt, support or debug these patches.
- **Report bugs where they belong.** If it also happens in the original Tinycast, report it
  [upstream](https://github.com/abue-ammar/tinycast/issues), following its templates and rules. If it
  only happens here, open an issue [in this fork](https://github.com/sermelipharo/tinycast-space/issues).
- **Support the author, not the fork.** The fork takes no donations. If Tinycast is useful to you,
  [tip Abue Ammar](https://buy.polar.sh/polar_cl_NDVFC20DKQpLcNawsh97QzbARBXD3WNn8v35R0mbJmT).

The contact email, Discord, sponsorship links and install instructions in the
[original README](README.upstream.md) all belong to the original project, not to this fork.

## License

[AGPL-3.0](LICENSE), the same as upstream. The complete source of every build published here, patches
included, is in this repository.
