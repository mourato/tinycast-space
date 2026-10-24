# Recipe tooling

This folder holds the recipe: the pins, the patches, and the code that materializes and drives the
source. Nothing here is Tinycast product code.

## Contents

| Path | Role |
| --- | --- |
| `recipe.py` | Owns every recipe operation: prepare, status, save, update, check-space, and the build, test, lint and install commands. |
| `sources.lock.json` | The pins and the expected source fingerprint. Written by `update` and `save`. |
| `space-radar.json` | The Space fork URL and the Space commit our Space-origin patches were adopted from. Read by `check-space`; edited by hand. |
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
| `make save` | Exports committed `.build/source` work to `.mine/patches/` and the lock. `REWRITE=1` permits a rewritten history rooted at the receipt checkpoint. |
| `make check-space` | Reports Space patch changes since the adopted commit. See [Space radar](#space-radar). Changes nothing. |
| `make update` | Selects the latest official Tinycast `main`. The release version is the newest reachable `v*` semantic version tag on that commit. |
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

Use `make save REWRITE=1` when the source history was intentionally reordered, squashed or split. The
rewritten HEAD must still descend from the receipt's source-only checkpoint; save keeps the previous
managed tip under `refs/tinycast/rewritten/` before publishing. Without `REWRITE=1`, the existing
managed-lineage guard remains in force.

Ignored files in `.build/source` survive `save`. They are never exported.

Do not export from a `mine-base..HEAD` range, reset `main`, or force-push. None of these match how the
recipe works now.

## Updating the pins

1. Run `make update`. It validates a complete candidate first.
2. Review `.mine/sources.lock.json`, then commit it.
3. Run `make prepare` to materialize the new pins. Then build, test and lint.

Only the lock changes. `.build/source` stays on the old pins until `make prepare` runs. A patch that does
not apply stops `prepare`, and the previously published source stays in place.

A patch that no longer applies after `make update` stops the candidate, and nothing changes. Rebase it:
run `make prepare` on the old lock, rebase the managed commits in `.build/source` onto the new upstream
commit, resolve the conflicts, commit, run `make save`, then run `make update` and `make prepare`.

Some patches carry generated files: `Tinycast.xcodeproj/project.pbxproj` and
`Tinycast/Resources/RaycastRuntime.generated.js`. Do not merge their conflicts by hand. Regenerate them
in `.build/source`: `xcodegen generate` for the project, or `pnpm install` and then `node build.mjs` in
`Scripts/raycast-runtime` for the runtime bundle. Then commit and continue.

## Space radar

Patches 0001–0028 came from the [Space](https://github.com/sermelipharo/tinycast-space) fork. Space is
no longer an input; we track it to adopt new work by choice.

`make check-space` reads `.mine/space-radar.json`, fetches the Space head read-only, and prints JSON:
the head, the upstream commit its `.space/UPSTREAM` records, and the `.space/patches` files added,
modified or removed since `adopted_commit`. It never changes the lock, the patches or `.build/source`.

To adopt a Space patch:

1. Apply or port it in `.build/source` and commit it. Add the trailer
   `Origin: tinycast-space <patch file> @ <Space commit>` to the commit message. The trailer is a
   convention for people; the recipe does not read it.
2. Run `make save`. It commits the patches and the lock.
3. When you have reviewed every change up to a Space commit, set `adopted_commit` in
   `.mine/space-radar.json` to it and commit that file. It is the only recipe input edited by hand.

## Recovery

- **Rewriting saved history.** Use `make save REWRITE=1` only for an intentional rewrite rooted at the
  receipt checkpoint. Save keeps the former managed tip in `.build/source` under
  `refs/tinycast/rewritten/<old-tip>` so the rewrite remains recoverable.
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
- **Prepare refuses changed inputs while source work is unexported.** `make prepare` fails when the lock
  or patches changed and `.build/source` has unexported commits. Export before you change the inputs:
  commit the work in `.build/source`, run `make save`, then run `make update`, and run
  `make prepare`.
- **Save refuses stale inputs.** `make save` rejects a source whose receipt records a different lock or
  patch digest. Committing source work does not clear this. Keep `.build/source`, its refs and every
  `.source-backup-*` directory. Then reconcile the inputs:
  1. Run `make status` and check `inputs_current`.
  2. Read `input.lock_sha256`, `input.patch_digest` and the top-level `patches` list (name and
     `sha256` per file) from `.git/tinycast-recipe-receipt.json` in `.build/source`.
  3. Find the commit whose `.mine/sources.lock.json` and `.mine/patches/` match them. Check the lock
     with `git show <commit>:.mine/sources.lock.json | shasum -a 256`, and each patch the same way.
  4. Copy any uncommitted lock or patch edits aside. `git restore --source <commit>` overwrites them.
  5. Run `git restore --source <commit> -- .mine/sources.lock.json .mine/patches`, then `make save`.
  6. Reapply the intended pin change with `make update`, then run `make prepare`. Do not
     copy the saved lock or patches back: `make save` just rewrote both.

  If no committed input set matches the receipt, stop. Do not reset `main`, re-tag, or delete the
  receipt or backups to force a save.

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
