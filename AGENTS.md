# Tinycast

This repository is a personal build recipe for Tinycast, a native macOS
menu-bar launcher by Abue Ammar. It pins one upstream commit, applies the local
patches in `.mine/patches/`, and builds the result. It holds no product source.
The product source sits in `.build/source`, a separate, git-ignored Git
repository. Tinycast is a one-hotkey command palette that also runs Raycast
extensions. A mistake here can lose unsaved product work or replace the
Tinycast app you run every day.

## What we never compromise

Each value below protects something this repository cannot rebuild from its own
files.

- **Unsaved product work.** `.build/source` and its `.source-backup-*`
  directories can hold commits and ignored files that exist nowhere else. Keep
  them until the work is saved or copied out.
- **Reproducible inputs.** The lock and the patches decide what gets built.
  Commands write them, so every change to them shows in a reviewable diff.
- **One owner per fact.** Each pin, command behaviour, and invariant has one
  home. A second copy drifts, and the two copies can then disagree.
- **The `Makefile` as the command surface.** Every operation runs through one
  target, so every agent and editor runs it the same way.

## Glossary

- **source** — `.build/source`, the product Git repository you edit. Its files
  are not in this repository.
- **lock** — `.mine/sources.lock.json`: the pinned upstream commit, release
  tag, and expected source fingerprint.
- **patches** — `.mine/patches/`: the local changes applied after upstream.
- **receipt** — `tinycast-recipe-receipt.json` in `.build/source/.git`.
  `prepare` writes it; `save` checks against it.
- **save** — `make save`: exports committed source work to the patches and the
  lock.
- **Space** — the fork at `sermelipharo/tinycast-space`. Patches 0001–0028
  came from it. Tracked to adopt new work; not an input.

## The ways to hurt yourself

Each hazard below damages state that a build cannot recreate, or the app you
already run. Each one names its safe alternative.

1. **Hand-editing the lock or the patches.** `make update` writes the lock, and
   `make save` writes the patches. `make save` rejects a source whose receipt
   records a different lock or patch digest. Use the command, then review its
   diff.
2. **Deleting `.build/source`, a `.source-backup-*` directory, or the save
   journal.** Each can hold unsaved work or the state of an interrupted save.
   Run `make save`, copy out anything you need, and keep the rest until then.
3. **Running `make install` to test a change.** It replaces
   `/Applications/Tinycast.app` and relaunches it. Test with `make build-debug`
   instead: it builds an unsigned `Tinycast Dev.app` under
   `.build/DerivedData` and leaves the installed copy alone.
4. **Rewriting history.** Do not export from a `mine-base..HEAD` range, reset
   `main`, or force-push. Use `make save REWRITE=1` only for an intentional
   rewrite rooted at the receipt checkpoint. Save keeps the former tip under
   `refs/tinycast/rewritten/` for recovery.
5. **Hand-merging generated files in a patch conflict.** Conflicts in
   `Tinycast.xcodeproj/project.pbxproj` and
   `Tinycast/Resources/RaycastRuntime.generated.js` need regeneration. Run
   `xcodegen generate` in `.build/source`, or `pnpm install` and then
   `node build.mjs` in `Scripts/raycast-runtime`. Then commit.

## Hit every surface

Before calling work done, walk this list and say which entries applied:

- **Recipe files.** `Makefile`, `.mine/`, `docs/`, `.vscode/`, `.github/`.
  Check each link, path, and name the file gives. Parse each JSON file.
- **Command surface.** `make help` lists the targets. `.vscode/tasks.json`
  calls `make -C` on the root, so a renamed target breaks the editor tasks.
- **Lock and patches.** Changed only through `make update` and `make save`.
  Prove them with `make prepare` on a clean clone, then `make build-debug`.
- **Product source.** `make test`, `make lint`, then `make build-debug`, run
  from the root against `.build/source`.

## Working here

Run every command through the `Makefile` from the repository root, for example
`make build-debug`. Run `make help` for the list. Do not call `.mine/recipe.py`
directly except where a doc names it. Each kind of change has one place to go:

- **Recipe tooling, docs, editor config, `Makefile`, `.github/`:** root, as an
  ordinary commit on the task branch. These never become patches.
- **Pins, patches, `.mine/sources.lock.json`:** written by commands, never by
  hand. `make save` writes the patches; `make update` writes the lock. The one
  hand-edited recipe input is `.mine/space-radar.json`; see `.mine/README.md`.
- **Product Swift, tests, product docs:** in `.build/source`. Run
  `make prepare`, read `.build/source/AGENTS.md`, edit and commit there, then
  run `make save` at the root.

Product invariants live in `.build/source/AGENTS.md` and its `docs/`. This file
does not restate them.

Read before you start:

- Before a change to lifecycle, artifacts, or validation, read
  [docs/agents/project-workflow.md](docs/agents/project-workflow.md).
- Before a review of recipe changes, read
  [CODING_STANDARDS.md](CODING_STANDARDS.md).
- Before a command, a pin update, or a save recovery, read
  [.mine/README.md](.mine/README.md).

Integrate a task worktree only with this project's `make finish-task`
([.mine/README.md](.mine/README.md#integration)), never the global agent-config
`ready-task` or `finish-task`. It merges fast-forward only, pushes
`origin/main`, then removes the worktree, its branch, and its DerivedData.

Bugs and feature requests for Tinycast itself go upstream, at
[abue-ammar/tinycast issues](https://github.com/abue-ammar/tinycast/issues).
Recipe work goes on a task branch; match the subject style of `git log`, for
example `fix(recipe): keep save journal on failure`. This repository has no CI
and no release process.

## Canonical abstractions

Each invariant has one owner. Do not add a second. Run `make recipe-test` after
any change to these owners.

- Pins: `load_lock` in `.mine/recipe.py`; use instead of parsing the lock
  directly; enforced by `test_malformed_lock_and_symlink_are_rejected` in
  `.mine/test-recipe.py`.
- Source fingerprint: `source_fingerprint` in `.mine/recipe.py`; use instead of
  hashing the source tree by hand; enforced by
  `test_prepare_materializes_new_pin_then_save_preserves_fingerprint`.
- Prepare receipt: `receipt_bytes` writes and `validate_receipt` checks the
  receipt in the source's `.git` directory; use instead of editing it; enforced
  by `test_missing_receipt_and_non_descendant_source_are_rejected`.
- Operation lock: `RecipeLock` on `.build/.recipe.lock`; use instead of running
  an operation without it; enforced by
  `test_install_holds_lock_until_worker_finishes` and
  `test_command_reuses_dirty_source_and_holds_lock_during_tool`.
- Save: `save` in `.mine/recipe.py`; use instead of exporting patches or copying
  files into `.mine/patches/` by hand; enforced by
  `test_save_exports_committed_source_and_preserves_unrelated_index` and
  `test_save_rejects_dirty_source_and_stale_authoritative_inputs`.

## Verifying

Each gate proves the change it covers. Report every result, including failures,
with the exact output line.

- Docs, `.vscode/`, `.github/`, `Makefile` help text: read the links and paths,
  parse each JSON file, and run `git diff --check`.
- `Makefile` targets, `.mine/recipe.py`, `.mine/test-recipe.py`: run
  `make recipe-test`.
- Lock or patches: run `make prepare` on a clean clone, then `make build-debug`.
- Product source: run `make test` and `make lint`, then `make build-debug`.
- `make status` reports the receipt state. It does not validate. A stale
  receipt after a lock change is expected until `make prepare` runs.

## Taste

Small, plain changes keep the recipe reviewable and its failures visible.

- One concern per commit. Put unrelated cleanup in its own commit.
- Shell scripts start with `set -euo pipefail` and quote every expansion. They
  stop on the first error and name the path or command that failed.
- Python in `.mine/` uses only the standard library, so it runs on the Python 3
  that macOS provides.
- Write `.vscode/` and other JSON as strict JSON: no comments, no trailing
  commas.
