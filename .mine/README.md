# Recipe tooling

This folder holds the recipe: the pins, the patches, and the code that materializes and drives the
source. Nothing here is Tinycast product code.

## Contents

| Path | Role |
| --- | --- |
| `recipe.py` | Owns every recipe operation: prepare, status, save, update, sync, check-space, and the build, test, lint and install commands. |
| `sources.lock.json` | The pins and the expected source fingerprint. Written by `update`, `sync` and `save`. |
| `patches/` | The saved patches, applied in name order. Written only by `save`. |
| `test-recipe.py` | Real-CLI tests for `recipe.py`. |
| `install.sh` | Replaces `/Applications/Tinycast.app` with a built Release app. Called by `make install`. |
| `finish-task.sh` | Integrates a task branch into `main`. See [Integration](#integration). |
| `prune-derived.sh` | Lists or removes Xcode DerivedData of deleted legacy worktrees. |
| `source-tree.sh` | Prints the source fingerprint of a Git tree. |

## Commands

Run each from the repository root. [`AGENTS.md`](../AGENTS.md) names the owners.

| Target | Effect |
| --- | --- |
| `make status` | Reads the lock and `.build/source`, then prints JSON. Changes nothing. |
| `make prepare` | Materializes `.build/source` from the lock, or validates the existing one. |
| `make build-debug` | Unsigned Debug build. Product: `.build/DerivedData/Build/Products/Debug/Tinycast Dev.app`. |
| `make build` | Signed Release build, verified with `codesign`. Product: `.../Release/Tinycast.app`. |
| `make install` | Release build, then replaces `/Applications/Tinycast.app` and relaunches it. |
| `make test` | Runs every harness in `.build/source`. `ARGS=<harness>` runs one. |
| `make lint` | Lints `.build/source`. `ARGS=--fix` applies the mechanical fixes. |
| `make save` | Exports committed `.build/source` work to `.mine/patches/` and the lock. |
| `make check-space` | Reads the current and available Space pins. Changes nothing. |
| `make update` | Selects the latest official Tinycast `main` and Space's maintained snapshot. |
| `make sync` | Selects Space's maintained snapshot and the upstream release it records. |
| `make recipe-test` | Runs `test-recipe.py`. |
| `make finish-task` | Integrates the current task branch. See [Integration](#integration). |
| `make prune-derived` | Lists stale legacy DerivedData. `ARGS=--apply` removes it. |

Build, test and lint each validate or materialize the source first. They use the version from the lock,
not from Git tags in this repository.

Artifacts stay in `.build/`: `DerivedData/`, `logs/{debug-build,release-build,test,lint}.log`, and
`source/`. Logs are truncated per run.

## Editing the product source

1. `make prepare`, then open `.build/source`.
2. Read `.build/source/AGENTS.md` before you edit.
3. Commit the change in `.build/source`. A dirty source cannot be saved.
4. Run `make save` here. It exports the committed work and commits the result.

`save` takes its input from a source-only checkpoint recorded in the prepare receipt. It replays that
checkpoint independently, checks the fingerprint, and publishes the patches, lock and receipt as one
transaction. Then it commits only `.mine/patches/` and `.mine/sources.lock.json`, with the message
`mine: save patches`. Other staged entries stay staged.

Ignored files in `.build/source` survive `save`. They are never exported.

Do not export from a `mine-base..HEAD` range, reset `main`, or force-push. None of these match how the
recipe works now.

## Updating the pins

1. Run `make check-space` to see what is available.
2. Run `make update` or `make sync`. Each validates a complete candidate first.
3. Review `.mine/sources.lock.json`, then commit it.
4. Run `make prepare` to materialize the new pins. Then build, test and lint.

Only the lock changes. `.build/source` stays on the old pins until `make prepare` runs. A patch that does
not apply stops `prepare`, and the previously published source stays in place.

## Recovery

- **Save commit failed after publication.** The patches and lock are already published and coherent, but
  they remain staged. Inspect with `git status` and `git diff --cached`. Fix the Git problem, then commit
  only `.mine/patches/` and `.mine/sources.lock.json`. A later `make save` may do nothing, because the
  content is already published.
- **Save journal or rollback snapshot is corrupt or missing.** `make save` refuses to continue. Keep
  `.build/.source-save-journal.json` and the `.build/.source-*` directories. Repair the data they hold
  before you retry. Do not delete them.
- **`.source-backup-*` directories.** Each source replacement keeps its predecessor here, including
  ignored files and local Git metadata. These can hold unsaved work. Keep them until you have saved or
  copied out anything you need.
- **Prepare refuses changed inputs while source work is unexported.** Commit the work in
  `.build/source`, run `make save`, then run `make prepare`.

## Integration

`make finish-task` merges the task branch into `main` (fast-forward only), pushes `origin/main`, removes
the worktree and branch, and removes that worktree's DerivedData. It reports `MERGE`, `PUSHED` and
`CLEANED` separately, and stops at the first failed stage.

Its preconditions:

- The branch name is lowercase kebab-case. Branches named `t3/...` are rejected.
- The source is saved. `finish-guard` refuses unexported changes, ignored files, pending recovery and
  retained backups.
- The task worktree is clean. `main` is clean and matches `origin/main`.
- The branch is based on the current `main`.

`finish-task` does not run validation and is not part of `save`. Run the gates first.

Worktree removal for `t3/...` branches is managed by the T3 Code app, not by this recipe.

## Cleanup of legacy DerivedData

`make prune-derived` is a dry run by default. It lists Xcode DerivedData whose workspace is a removed
legacy worktree. `ARGS=--apply` deletes that data. It never matches the main checkout or a live
worktree. Review the dry-run output before you apply it.
