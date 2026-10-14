# Context

What Quick AI and AI Chat may quote, staged as visible text before it is ever sent. The pane is
**Settings → Context**; the workflow is shared: Quick AI's ⌘K menu and the AI Chat composer's `+`
menu offer the same ordered sources, and `@app` / `@tab` type the same picks as commands.

## Invariants

- **Capture is off until it is switched on here, and off means fully off.** `contextAppEnabled`
  and `contextBrowserEnabled` are the masters: with them off there are no reads, no prompts and no
  history opened. The auto-attach switches stage nothing on their own either. All four are excluded
  from settings backups and from `settings.json` like every other capability grant, so an import or
  a file can never arm capture — `settings-file-test` pins those paths absent.
- **Enabling a source never grants capture.** The Context Items switches only show or hide that
  source in the pickers; a switched-off source disappears from suggestions and manual menus and
  cannot auto-attach. Priorities only order the rows. Memory groups and Variables have no engine in
  this build: their rows stay disabled with the reason, never as live controls.
- **Every control does something.** There are no enabled no-op rows: masters gate capture, autos
  gate staging on open, selection-only changes what a quote holds, include-origin changes whether a
  quote names its source, prioritize-active reorders the pickers, and each priority stepper moves
  its source. `ContextPolicy` is the whole rule and it is pure; `context-test` pins selection
  precedence, gating, ranking, payload shape and the stale-capture boundary.
- **Staged context is an attachment, never a silent fetch.** A quote becomes a `text/plain`
  `AIDocument` in `pendingAttachments`, shown as a chip and removable, riding the existing
  attachment pipeline. Regenerate re-asks the stored question with its stored attachments and never
  re-reads. Automatic capture stages before send, never inside it; removing a staged quote opts its
  source out until the chat turns over, and no keystroke or send reattaches it.
- **One owned capture per destination.** A newer capture cancels the older; a late read publishes
  only while its ticket — operation, chat and source — is still current, capture is still enabled
  and nothing cancelled it. Switching capture off cancels in-flight reads; staged quotes stay,
  owned by the reader who can still remove them.
- **The root target predates focus.** The palette records the front app before it takes key and
  keeps it across mode switches; the AI Chat window records it before it shows. Tinycast itself is
  never a target. App context is metadata plus the focused window's accessible selection — the
  whole value only when selection-only is off — bounded and marked partial when cut, never claimed
  complete. Secure text and Secure Event Input refuse the text; the title may still be quoted.
- **Helium is the only browser, by its checked dictionary.** Tabs list on demand over normal
  windows; private windows never list and never auto-capture. Capture binds the stable tab and
  window ids and verifies the URL before publishing — a moved tab is stale, and stale is refused,
  never sent as URL-only. The page runs one fixed read-only reader; its text is untrusted data in
  the attachment, its origin URL sanitized, and nothing in it may imply instructions or tools.
  Automation denial, timeouts, loading, restricted and empty pages all report instead of sending.
  No borrowed ⌘C, no URL downloading as a stand-in for logged-in content.
- **Actions, integrations and tools attach as descriptions, never as runs.** A Quick Action rides
  with its prompt text; an MCP server or tool rides with its metadata, honouring `aiEnabled`,
  `mcpEnabled`, the chat's tool scope and existing trust. Attaching one enables and calls nothing,
  and no second MCP client is made. Where the model cannot call tools the rows say so, as the
  Tools menu already does.
- **`@server` keeps its meaning.** A leading `@slug` still scopes the turn to that server; `@app`
  and `@tab` quote the active app or tab and then send as one turn, and any other mention stays
  plain text. Live browser and TCC behaviour is a manual gate: no probe runs during implementation
  or in the suite, whose fixtures stand in for Helium.

## Manual sweep

- The Context tab is found by Settings search; every group reads in Dark and Light at native size.
- With everything off, opening either chat stages nothing and offers picks that explain themselves.
- Enable app context, summon Quick AI from Notes with a selection: the quote chip names the note;
  send, and the transcript carries the quoted text marked untrusted.
- `@app summarize` in either composer captures, then sends as one turn; `@tab` does the same for
  the active Helium tab. An unknown `@mention` sends as plain text.
- Deny Automation for Helium (or quit it) and attach a tab: the notice names the fix, and nothing
  is sent URL-only. Navigate the tab between listing and capture: stale is refused.
- Switch capture off mid-read: nothing lands. Remove an auto-staged quote and re-summon: it does
  not come back until a new chat.
