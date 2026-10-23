# Fork tooling and patches

This folder holds everything that belongs to running this fork and nothing that belongs to Tinycast:
the patch stack, the scripts that build and integrate it, and this note. `main` is a base plus the
patches exported from it.

## What is a patch

Every commit after the `mine-base` tag is a candidate patch. `make save` exports it as one file in
`.mine/patches/`, but only for paths outside `.mine/` and `Makefile`. So:

- Code, tests, docs, assets and `Scripts/` changes are patches. Replayed on a new base with `git am -3`.
- Anything under `.mine/`, and the `Makefile`, is tooling. It never becomes a patch. `rebuild.sh` carries
  the current copy over the rebuilt base, so it survives a rebuild unchanged.
- `.gitignore` is the one exception. It is shared with upstream, so it cannot be carried or excluded
  safely, and the `.worktrees/` rule stays a patch.

## Adding a patch

1. Create a task worktree with `"${AGENT_CONFIG_HOME:-$HOME/.agents}/scripts/new-worktree.sh" <slug>`.
   It creates `.worktrees/<slug>` on branch `<slug>`, and `.worktrees/` is git-ignored.
2. Commit in the worktree. Match the subject style of `git log`.
3. Validate: `./Scripts/run-tests.sh` passes, `./Scripts/lint.sh` is clean, and the Debug build adds no
   warnings. Do this before integrating, because `make finish-task` runs no checks.
4. `make save`, in the task worktree. It rewrites `.mine/patches/` from the commits and commits
   `mine: save patches`, so the export merges with the task.
5. `make finish-task`, in the task worktree.

## Targets

- **`make save`** runs `.mine/save-patches.sh`, as above.
- **`make finish-task`** runs `.mine/finish-task.sh` from a task worktree. It fast-forwards `main` to the
  task branch, pushes `origin/main`, then removes the worktree and the branch, and the worktree's Xcode
  DerivedData. It reports `MERGE`, `PUSHED` and `CLEANED` on separate lines. It stops before the merge on a dirty task worktree, a dirty `main`, a
  `main` that differs from `origin/main`, or a branch not based on `main`. Rebase the branch and run it
  again. A failed push keeps the worktree and branch, so the run can be repeated.
- **`make prune-derived`** runs `.mine/prune-derived.sh`. It lists `Tinycast-*` DerivedData whose
  `WorkspacePath` is a `.worktrees/<slug>` that no longer exists, and `make prune-derived ARGS=--apply`
  removes them. It is dry-run by default and never matches a live worktree or the main checkout.
- **`make sync`** and **`make update`** run `.mine/rebuild.sh`. It refuses a dirty tree and a `main` that is
  not checked out. `make update` first applies the incoming Space patches on a disposable worktree; a
  preflight conflict leaves `main` untouched. After that it saves the patches, creates
  `backup/main-<timestamp>`, resets to the new base, carries `.mine/` and `Makefile` over from the old
  tree, retags `mine-base`, and replays `.mine/patches` with `git am -3`. If the Space phase fails, the
  backup is restored automatically; if a local patch conflicts, the new base remains in place for manual
  resolution and `.mine/` plus `Makefile` are restored before the command exits. It never pushes.
  A conflicting local patch stops it: fix the files, `git add`, `git am --continue`, then `make save`.
  To abandon that rebuild, run `git am --abort` and then `git reset --hard backup/main-<timestamp>`.
  The push is by hand, after review: `git push --force-with-lease origin main`.

## The Space pipeline is separate

`.space/patches/` and `.space/apply.sh` belong to the published Space pipeline, described in
[.space/README.md](../.space/README.md). Nothing here reads or writes them.
