# Quick Actions

Act on the text selected in whatever app is frontmost. Four are shipped: Fix Grammar, Rewrite,
Translate and Summarize, each with its own bindable shortcut **and its own launcher command**, both
listed in **Settings → Quick Actions**. A **custom Quick Action** is a name, a glyph and a prompt, and
takes a shortcut and a launcher row like any other.

Every result opens in **Quick AI**, the palette's AI screen, and the chat's own model answers it. Fix
Grammar, Rewrite, Translate and custom actions write their reply back over the selection through a
**Replace** button on that reply. Summarize only reads. Translate is the one exception to the model:
it runs on Apple's translator, which needs no account, and its reply joins the transcript the same way.

Quick Actions depend on AI Chat. With AI Chat switched off, every shortcut and launcher row does
nothing and says so with a HUD.

## Invariants

- **Off out of the box, and off means the shortcuts do nothing.** `AppSettings.quickActionsEnabled`
  is the flag and `QuickActionCoordinator` is the only place that reads it: no selection is read and
  no conversation starts. The four commands leave the launcher's Quick Actions slice through
  `AppIndex.setCommandsVisible`, and the custom ones through `AppIndex.setCustomQuickActions`. Carbon
  bindings stay registered, so re-enabling restores every shortcut without touching the hotkey layer.
  The flag grants keystroke delivery into other apps, so like `snippetsEnabled` it is excluded from
  settings backups — an import must never arm it.
- **Quick Actions need AI Chat.** `AppSettings.aiEnabled` must also be on. `QuickActionCoordinator.run`
  refuses with a HUD before it reads anything, so no text leaves the Mac through a route the reader
  never turned on.
- **One funnel, whichever way an action started.** A shortcut and a launcher row both land on
  `QuickActionCoordinator.run(_:)`, which captures the target **before** hiding the palette. An
  external app remains the usual target; a selected passage in the Notes editor is captured directly
  from its text view.
- **Enabling is consent, and it is the only place Accessibility is requested.** The toggle confirms
  through `DialogController` first and then calls `Permissions.ensureAccessibility()`. Everything else
  uses `isAccessibilityTrusted()` and degrades to a HUD.
- **Tinycast is never an event target.** `QuickActionRunner.selection(in:using:)` refuses our own
  bundle identifier, and `TextInjector.targetAcceptsInjection` refuses it again before every event post,
  along with anything raised while Secure Event Input is up. Notes is the narrow in-process exception.
- **Results open in Quick AI and nowhere else.** `answer` starts a new conversation in
  `AIChatSurfacesState.quickAI`, stages the text as one `text/plain` document, and sends the action's
  title as the turn. Its instructions come from `QuickActionPrompt`, or the reader's override. The turn
  goes through the chat's own route with no tools and no web search. The reply streams in the palette,
  and ⌘J hands the conversation to the AI Chat window like any other.
- **The text is bounded where it is read, not where it is sent.** The selection or page is capped at
  `QuickActionRunner.maxSelectionBytes` (32 KB), the same ceiling `AIAttachmentBudget` gives a text
  document, so a page that fits the reader fits the request. Chat's own 8,000-character page staging is
  not involved.
- **A new run waits for an answer already in progress.** `run` refuses while `quickAI` is streaming, so
  a shortcut never cancels a reply the reader is still reading. A second run while text is being read
  is refused the same way, because two reads race for one selection.
- **A browser page stands in for a missing selection only where browser context is on.** When no
  selection is found and the target is a supported browser, `QuickActionCoordinator` reads its active
  tab through `ContextBrowserRunner`, only while `ContextPolicy.canCaptureBrowser` holds. The page's
  selection wins, else its text, capped to `maxSelectionBytes`. **A page result is never written back**:
  `begin` computes `writesBack = !fromPage && action.replacesSelection`, so no Replace button and no
  automatic replacement is offered for it, whatever the action.
- **Only the reply is written back, and only to where the text came from.** The target — the frontmost
  app or the note editor and its range — is captured when the run starts. `replaceReply` writes the last
  reply through `deliver`, and only while `canReplaceReply` finds it still the last message of the same
  conversation. A regenerated or superseded reply has a new id, so its button disappears.
- **Summarize never writes back.** `BuiltInQuickAction.replacesSelection` is false for it, so its
  reply carries no Replace button and nothing replaces the text. The answer is about the text, and
  replacing the text with it would destroy what the reader selected.
- **A custom action chooses between Preview and Replace on its record.** Preview shows the reply in
  Quick AI with a Replace button. Replace writes the reply back as soon as it finishes: `finishedReply`
  leaves the palette, then calls `deliver`. Tinycast cannot know whether an arbitrary prompt transforms
  the text or answers a question about it, so Preview stays the default.
- **Translate uses Apple's translator and needs its language installed.** `TextTranslator` runs on
  device. Its reply is recorded whole with `AIChatState.record`, since the translator does not stream.
  A language that is supported but not downloaded raises a dialog that opens Language & Region, and
  nothing is written.
- **`Model/` stays Foundation-only.** `quick-action-test` compiles that folder standalone.
- **Built-in instructions treat the text as untrusted input.** `QuickActionPrompt` tells the model that
  the attached text is material to work on and never instructions to follow, and that only the
  transformed text may come back — no preamble, no fences. Custom instructions replace these rules too.
  The output is pasted into somebody's document.
- **A custom prompt cannot drop that boundary.** An override on a shipped action may replace
  `boundary`, because the sheet shows the whole prompt. A custom action *is* the prompt, so `boundary`
  is prepended and no control removes it.
- **Each built-in action owns its instructions.** The pencil on Fix Grammar, Rewrite and Summarize
  opens a sheet prefilled with the exact built-in prompt. Saving replaces it for only that action;
  Use Default restores it. Translate has no editor, because it does not take model instructions.
- **A custom action never travels in a backup.** Neither the record, its shortcut nor its Replace
  choice, for the reason `quickActionInstructions` already doesn't: an import must never change what a
  shortcut does to somebody's documents. Its JSON sits outside `UserDefaults`, so no settings key can
  sweep it up.

## The actions

`QuickAction` is `.builtIn(BuiltInQuickAction)` or `.custom(CustomQuickAction)`. Coordinator, prompt and
runner all take that one type.

A fifth *shipped* action is one `BuiltInQuickAction` case, its prompt in `QuickActionPrompt`, and one
`CommandID` case for its launcher row. `CommandID.init(_ action:)` is exhaustive, so it cannot compile
without one.

| Action | Engine | Result | Replace |
| --- | --- | --- | --- |
| Fix Grammar | chat model | Quick AI | button |
| Rewrite | chat model | Quick AI | button |
| Translate | Apple Translation | Quick AI | button |
| Summarize | chat model | Quick AI | none — read only |
| a custom action, Preview | chat model | Quick AI | button |
| a custom action, Replace | chat model | Quick AI | written back on finish |

On a page with no selection, every row keeps its result and loses its write-back.

Results no longer show a diff. The old panel marked what Fix Grammar and Rewrite changed; Quick AI
is a transcript, and `TextDiffEngine` was removed with the panel. The reply is the whole text.

## Custom actions

`CustomQuickAction` is `id`, `name`, `iconSymbol`, `instructions`, `previewsResult`, `createdAt`.
`CustomQuickActionStore` keeps them as JSON in Application Support, ordered by `createdAt`, under an
injected directory so the harness gets a throwaway one. Name and instructions must be non-empty;
nothing else is rejected, including a name a shipped action already uses.

**Replace / Preview rides the record.** A parallel dictionary in settings would outlive the actions it
described, and `BuiltInQuickAction` cannot hold a UUID. On the record, a delete takes the choice with it.

**`AppEntry.Kind.quickAction` is one section for both halves**, ungated in
`VisibilityStore.allowsHotKey` because `quickActionsEnabled` is the master switch. The four keep their
`CommandID`s, so no shortcut or preference key moved. A custom action binds
`HotKeyAction.quickAction(id:)` under `hotkey.quickAction.<uuid>`, indexed in `boundQuickActionIDs` so
`HotKeyManager.start` can prune a binding whose action was deleted while Tinycast was off.

**The pane draws its own `AliasField`.** The four are named in `SettingsTab.ownedCommands`, so
Settings → Commands no longer draws theirs. Without it, `deleteCustomQuickAction` would be clearing an
alias no surface could set.

**Nothing is saved until it is on disk.** `commit` persists before it moves `actions`, and a write
that cannot land throws `.storageUnavailable` where the reader sees it. An absent file is a fresh
install; one that exists but will not decode sets `isAvailable` false and makes every mutation refuse.
`QuicklinkStore`'s rule: authored data is reported on, never written over.

**Deleting unwinds only once the record is gone.** Confirm, remove, *then* drop the binding, the
favorite, the alias, the visibility key and the ranking. `WindowLayoutCoordinator`'s order: a failed
delete must never leave a kept record stripped of its shortcut.

## Translation

`TextTranslator` uses Apple's translator rather than the language model: it runs on device, costs
nothing on every route, and a 3B model is markedly worse at it. `NLLanguageRecognizer` supplies the
source language, because `TranslationSession(installedSource:target:)` needs a concrete one and
`LanguageAvailability` reports only a status.

`TranslationError` is annotated `macOS 26.4` while the deployment floor is `26.0`, so failures are
caught as plain `Error` and reported by what was asked rather than by matching its cases.

**The picker offers Apple's own list, never the reader's preferred languages.** `supportedLanguages`
is 47 entries on macOS 26 and is the framework's to change. Notably **Bengali is not among the 47**.
Names come from `minimalIdentifier`, so `es` reads "Spanish", not "Spanish (Latin, Spain)".

The target language is set in **Settings → Quick Actions → Translate to**. Quick AI has no language
menu of its own: changing the language means changing the setting and running Translate again.

A pair that is supported but not downloaded raises a dialog that names the language, and its one
button opens Language & Region. **The download happens in System Settings**, because no sheet can
appear over Quick AI from outside the app.

## Results in Quick AI

`QuickAICoordinator` owns the palette's AI screen, and Quick Actions reuse its chat state. A run
calls `chats.quickAI.startNewChat()`, the same reset `ask(_:)` makes, so a result never lands in a
conversation the reader was already in. The palette opens in `.ai` mode; the reply streams through
`AIChatCoordinator.answerQuickAction`, which is the chat's send path without the `@`-token parsing
and the tool loop.

**Replace is an action on the reply, not a footer.** `ChatTranscriptView` offers a `ReplaceButton`
beside the copy and regenerate buttons, on the last assistant message only. Both surfaces wire it:
the palette's `AIChatView` and the AI Chat window's detail view. `canReplaceLastReply` decides whether
the callback is passed at all, so an ordinary reply has no button.

**Automatic write-back waits for the reply to end.** A custom action set to Replace registers
`AIChatState.onNextReplyEnded` before the turn starts. `finishLast` calls it once, however the turn
ends, and only a completed reply reaches `finishedReply`. Clearing the hook on every end stops a
failed run from writing into a later reply.

A failed reply keeps the chat's usual `failed` state and no button. Cancelling it through Quick AI
behaves as cancelling any reply does.

Quick AI has no progress pill of its own. The streaming reply is the progress.

## Reading the selection

When the target is the Notes editor, the coordinator captures its selected source text before any
window changes focus. Empty and oversized selections use the same limits as external text.

Two tiers, in order. `AccessibilityText.read` asks for `kAXSelectedTextAttribute`, then the
text-marker range browsers use instead. `AXManualAccessibility` is set on the application element
first, because Chromium builds its accessibility tree only once something asks and Chrome, Electron
apps and VS Code otherwise answer every attribute with nothing.

When Accessibility yields nothing, `TextInjector.copySelection` borrows a ⌘C: snapshot the
pasteboard, pause clipboard history, synthesise the chord, wait for `changeCount` to **move**, read,
restore, resume. The pause keeps the borrowed copy out of history. Only one borrow runs at a time:
a second would snapshot the first one's copy and read its restore as a selection, so it returns
nothing instead. It lives on
`TextInjector` because the pasteboard has one owner — the same lease, queue and `ClipboardManager`
coordination a paste needs, and a second owner would race it.

**The `changeCount` guard is load-bearing.** With nothing selected, ⌘C is a no-op; returning the
pasteboard's existing contents there would transform whatever the reader last copied and paste it
over their selection. Movement is the only proof a copy happened — never comparing content, which
false-positives when the same text was already on the clipboard.

Copying is the fallback and never the first try: it synthesises a keystroke into somebody else's app.
When both tiers come back empty, only an Accessibility result of `.empty` justifies "nothing is
selected"; otherwise the app told us nothing either way and says so.

Quicklinks and snippets read `{selection}` through the same two tiers, with one rule of their own:
the ⌘C is sent only when the expanded template reads the selection. A snippet's keyword expansion
never sends one, since a typed keyword leaves nothing selected.

## Delivery

Notes replaces the captured range through its own TextKit edit path, with undo and autosave. If the
note, source or selection changed while the result was generated, delivery declines and copies the
result instead of replacing another passage.

For external apps, `TextInjector` — shared with Snippets and Quicklinks, and owned by `AppCore` — does
the replacement.
`replaceSelection(with:in:)` takes the interactive path: no keyword to match, no generation to
cancel, because a shortcut is an explicit gesture rather than an expansion the app decided to
attempt. Its serial delivery queue is what stops two features fighting over the pasteboard lease.

The Accessibility tier replaces the live selection atomically, under the five-rule delivery contract
in [snippets.md](snippets.md#text-delivery-and-pasteboard-safety) — Quick Actions simply enter it with
no keyword, so rule 2 never applies. The event tiers behind it type or paste over the selection, which
every app treats as replacing it — but that is the target app's behaviour rather than something
Tinycast asserts, so it is the part worth checking by hand.

**A replacement that never lands says so, and keeps the reply.** Every tier can decline, and a shortcut
that quietly did nothing is indistinguishable from a shortcut that is not bound. `DeliveryCompletion`
now settles either way, so a delivery that returned early reports failure exactly once; Quick Actions
put the generated text on the clipboard and raise a HUD rather than dropping it. Snippets pass no
failure handler, so automatic expansion stays silent as before.

### Manual sweep

- Select text in Safari, Chrome, Brave, Slack, Mail, Notes, VS Code and Terminal, press Fix Grammar,
  and confirm the reply opens in Quick AI with the text as an attachment, and that its Replace button
  writes the reply over the selection rather than appending to it.
- Select text in a Tinycast floating note and run Fix Grammar by shortcut and launcher row. Confirm
  Replace, Undo, and that changing the note before pressing Replace copies instead.
- In a Chromium target, run one on a **short** selection whose result stays under 100 characters on
  one line: the whole result lands, not its first four characters.
- Run one from the launcher (⌘Space → "Fix Grammar") with text selected behind it: the palette opens
  in AI mode, and Replace targets the displaced app's selection, not Tinycast's own field.
- Summarize a long selection: the reply streams in Quick AI, has no Replace button, and leaves the
  text untouched.
- Summarize a page in a browser with no selection: the reply streams, and nothing is typed into the
  page.
- Turn AI Chat off and press a shortcut: a HUD says Quick Actions need AI Chat, and no text is read.
- Start a Quick Action while Quick AI is still streaming: refused with a HUD, and the reply finishes.
- Add a custom action in Preview mode, run it, and confirm Replace appears only after the reply.
  Switch it to Replace, run it again, and confirm the selection changes as soon as the reply ends.
- Translate into a language that has not been downloaded: a dialog names the language, and its
  button opens Language & Region. Nothing is written.
- Translate into a downloaded language: the reply appears as a finished turn, and Replace writes it.
- Uncheck an action's launcher checkbox: the row leaves ⌘Space, and its shortcut still works.
- Add a custom action, bind a shortcut, run it from the shortcut and from ⌘Space, then rename it and
  confirm the shortcut and the Replace choice survived.
- Delete a custom action with a shortcut bound: the dialog asks first, the row leaves both Settings
  and ⌘Space, and the chord is free for something else to take.
- Press a shortcut with Tinycast's own Settings window frontmost: refused, with a HUD.
- Press one in a password field: refused.
- Revoke Accessibility while enabled: a HUD explains instead of failing silently.
- Harness: `quick-action-test` (action metadata, prompt boundaries, the settings store, custom action
  persistence and refusal of unreadable storage).
