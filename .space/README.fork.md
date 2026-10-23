# ✨ Tinycast Space Edition

**Tinycast Space Edition** is an unofficial, automatically synced fork of **[Tinycast](https://github.com/abue-ammar/tinycast)** by
[Abue Ammar](https://github.com/abue-ammar), with a few small patches on top.

Everything that makes Tinycast good is the original author's work. This fork only carries the handful
of changes listed below. For what Tinycast is and how to use it, read the
**[original README](README.upstream.md)**, which is kept verbatim.

## What's different in this fork

| Change | Why |
| --- | --- |
| **Alias + Space.** Type an alias exactly and press Space (or Tab): a command with inline arguments jumps into its first field, a search command whose arguments are all optional opens so you type straight into its own search (`brew` → Search Homebrew), anything else opens, so you keep typing inside it, the way Raycast does. Apps and settings panes keep searching. See [Alias + Space](#alias--space) for the rules. | Muscle memory from Raycast. Declined upstream ([#696](https://github.com/abue-ammar/tinycast/issues/696), [#908](https://github.com/abue-ammar/tinycast/issues/908), Tab: [#1594](https://github.com/abue-ammar/tinycast/issues/1594)). |
| **Updates come from this fork.** The in-app updater and the About link point here. | So an installed fork build is never replaced by an upstream build without the patches. |
| **Extension runtime fixes.** `querystring.stringify` coerces `undefined` to `""` and `require("buffer")` exposes `Blob` and `File`, both as Node does; a bundled undici sends its requests through Tinycast's own `fetch` instead of sockets. | Without them, Google sign-in in extensions such as 2FA Code Finder fails with `invalid_client`, and extensions bundling undici (Google Translate) crash on load or fail with `net.isIP` is not supported. |
| **Edit aliases and shortcuts from ⌘K.** Every launcher entry's ⌘K menu has *Change Alias* and *Change Shortcut* rows that edit in place, extension commands included. | Faster than a trip to Settings. Ported, with thanks, from [jhasubhash/tinycast](https://github.com/jhasubhash/tinycast). |
| **Confetti.** Raycast's celebration: a *Confetti* command among the system actions, and `raycast://confetti` / `tinycast://confetti`, which is what extensions fire when a timer or task finishes. Every parameter is a `confetti.*` default, so it can be retuned without a rebuild. With Reduce motion on, a 🎉 shows instead of the animation. | Extensions call that link; upstream Tinycast ignores it. |
| **Raycast themes.** Settings → General → Appearance → *Light theme* / *Dark theme*, switched with the appearance like in Raycast, including Raycast's background gradient. Pick from ray.so's community themes with a live preview on hover, or from your installed ones with the *Theme* command, where the window takes each theme as you move through the list. In the Raycast Explorer extension the highlighted theme previews the same way, and *Add to Raycast* asks whether to use it. Your own themes come in as `raycast://theme` links from ray.so or Raycast's Theme Studio (*Import Link from Clipboard*). | Upstream declined themes ([#640](https://github.com/abue-ammar/tinycast/issues/640)). The themes are their authors', via [raycast/ray-so](https://github.com/raycast/ray-so) (MIT). |
| **More extensions work.** A command-line tool that isn't installed fails the way Node reports it (`spawn … ENOENT`), so an extension can fall back, and tools are looked up on the `PATH` the extension passes; streams and `http` cover what the `got` HTTP client needs. `http.STATUS_CODES` and `http.METHODS` are filled in, and a sign-in that fails or is cancelled no longer leaves the extension hanging; two sign-ins at once wait their turn. | Declined upstream as Raycast compatibility ([#1585](https://github.com/abue-ammar/tinycast/issues/1585), [#1592](https://github.com/abue-ammar/tinycast/issues/1592)). Based on fixes in [mSarheed/pipcast](https://github.com/mSarheed/pipcast). HTTP tables and sign-in recovery from [mSarheed/pipcast](https://github.com/mSarheed/pipcast). |
| **Extensions behave as in Raycast.** ⌘↵ runs an action panel's second action (the ⌘K panel shows ↵ and ⌘↵ beside the first two); a deeplink's `context` reaches the command as `launchContext`; a Form's `autoFocus` field takes focus; `icon@dark` artwork is used in dark mode; long lists stay quick on ↑/↓. | Declined upstream ([#793](https://github.com/abue-ammar/tinycast/issues/793), [#1452](https://github.com/abue-ammar/tinycast/issues/1452), [#1495](https://github.com/abue-ammar/tinycast/issues/1495)). The list fix is from [Tukks/tinycast](https://github.com/Tukks/tinycast), the dark icons from [jhasubhash/tinycast](https://github.com/jhasubhash/tinycast). |
| **Launcher keys.** While you type, ⌘1–⌘9 open the first nine results (hold ⌘ to see the numbers). The launcher hotkey hides the palette whichever screen it shows, and the next press brings that screen back. A query nothing matches is read as a typo, so `chorme` still finds Chrome; a query that matches anything is ranked exactly as upstream ranks it. ⌘I on an app opens its Finder *Get Info* window, as in Raycast (also *Show Info in Finder* in the ⌘K menu). | Requested upstream again and again ([#1357](https://github.com/abue-ammar/tinycast/issues/1357), [#1113](https://github.com/abue-ammar/tinycast/issues/1113)); Get Info was declined there ([#1326](https://github.com/abue-ammar/tinycast/issues/1326)). The hotkey change is from [songhyun-k/tinycast](https://github.com/songhyun-k/tinycast), typo matching from [arthur-fontaine/smallcast](https://github.com/arthur-fontaine/smallcast). |
| **Deeplinks to everything.** `tinycast://open?id=…` opens any launcher entry the way Return does, and every entry's ⌘K menu has *Copy Deeplink* (extension commands copy `tinycast://extensions/…`). A link only opens what the launcher lists; it carries no arguments, and actions such as Shut Down still ask first. A link fired from another app acts on that app, so window commands and snippets land where you are. | For Leader Key, BetterTouchTool and Shortcuts. Declined upstream ([#1005](https://github.com/abue-ammar/tinycast/issues/1005)). Focus hand-back after [mSarheed/pipcast](https://github.com/mSarheed/pipcast). |
| **Clipboard and snippets.** *Images Only* lists image files copied in Finder. Search Snippets has *Copy to Clipboard* (⌘↵; *Show in Finder* moves to ⌘F). A text entry in Clipboard History saves as a snippet with ⌘S. In Clipboard History, ⌘1–⌘9 open any of the first nine entries, and after *Save as Snippet* you are back on the same entry. | As in Raycast; declined upstream ([#1595](https://github.com/abue-ammar/tinycast/issues/1595), [#1333](https://github.com/abue-ammar/tinycast/issues/1333)). The image filter is from [mourato/tinycast-space](https://github.com/mourato/tinycast-space). Numbering and the return trip after [mSarheed/pipcast](https://github.com/mSarheed/pipcast). |
| **Search settings, words and folders.** `?` in the launcher searches Tinycast's own settings. The dictionary suggests spellings for a word it doesn't know. In File Search, Tab on a folder searches inside it. | Ported from [mSarheed/pipcast](https://github.com/mSarheed/pipcast). |
| **Small fixes.** Currency rates are never overwritten by an older refresh. *Check for Updates* says why it failed (offline, GitHub's rate limit). Long lists group by date faster, and launch no longer waits on the login-item check. | Bugs upstream shares; fixes from [mSarheed/pipcast](https://github.com/mSarheed/pipcast). |
| **Hyper glyph for external remappers.** With Hyper Key set to None, *Show ✦ for another app's Hyper key* still shows ✦ for the Hyper chord. | For Hyper keys provided by Karabiner, Hyperkey and similar apps. |

## Alias + Space

- **Only an exact, case-sensitive match jumps in.** With `cc` as the alias of *Change Case*, `cc` + Space
  opens it, while `CC` + Space (Shift held) or `Cc` + Space just keeps searching. It works the other way
  round too: give a command an alias like `CC`, and lowercase typing never jumps into it. Search and
  ranking stay case-insensitive; only the jump cares about case.
- **`\` + Space escapes the jump.** Type a backslash right before the Space and it becomes a plain space:
  `cc\` + Space turns into `cc ` and searches for everything starting with "cc".
- Apps and System Settings panes never jump: `tg something` searches rather than launching Telegram.
- **Only at the end of what you typed.** With the caret in the middle of the query or text selected,
  Space is just a space.
- **Tab does the same** under the same condition. Anywhere else Tab keeps its usual jobs: moving between
  argument fields and switching to Clipboard History or AI Chat.

Each change is a small patch in [`.space/patches`](.space/patches) and lands on `main` as its own commit,
so one feature can be read, reverted or cherry-picked alone; [`.space/README.md`](.space/README.md)
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
  If you have it through Homebrew, run `brew uninstall --cask tinycast` *before* installing the fork;
  the fork updates itself. Already installed the fork over it? Then don't: that command deletes
  `/Applications/Tinycast.app`, which is now the fork. Drop only Homebrew's record instead:
  `rm -rf "$(brew --prefix)/Caskroom/tinycast"`. (Pointed out by
  [mourato/tinycast-space](https://github.com/mourato/tinycast-space).)
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
