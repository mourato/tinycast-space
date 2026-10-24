#!/bin/bash
# Integrates the task worktree this runs from into main, pushes origin/main, then removes the
# worktree, its branch and its Xcode DerivedData. Run it as `make finish-task`; each stage stops the run
# before the next.
set -euo pipefail

say() { printf '%s\n' "$*"; }
fail() { printf 'FINISH_TASK: BLOCKED reason=%s\n' "$1" >&2; exit 1; }

task="$(git rev-parse --show-toplevel)"
branch="$(git -C "$task" symbolic-ref --quiet --short HEAD)" || fail "detached HEAD"
[ "$branch" != main ] || fail "run from a task worktree, not main"
[[ "$branch" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail "branch must be lowercase-kebab-case"
python3 "$task/.mine/recipe.py" finish-guard || fail "source-saved guard failed"
[ -z "$(git -C "$task" status --porcelain)" ] || fail "task worktree is dirty; commit first"

primary="$(git -C "$task" worktree list --porcelain \
  | awk '/^worktree /{path = substr($0, 10)} /^branch refs\/heads\/main$/{print path; exit}')"
[ -n "$primary" ] || fail "main is not checked out in any worktree"
[ -z "$(git -C "$primary" status --porcelain)" ] || fail "main worktree is dirty; preserve it and retry"

git -C "$primary" fetch --quiet origin || fail "fetch failed; fix connectivity and retry"
[ "$(git -C "$primary" rev-parse main)" = "$(git -C "$primary" rev-parse main@{upstream})" ] \
  || fail "main is not synchronized with origin/main; fast-forward it and retry"
git -C "$primary" merge-base --is-ancestor main "$branch" \
  || fail "$branch is not based on current main; rebase it and retry"

say "MERGE    branch=$branch target=main strategy=ff-only"
git -C "$primary" merge --ff-only --quiet "$branch" || fail "fast-forward merge failed"

say "PUSH     target=origin/main"
git -C "$primary" push --quiet origin main || fail "push failed; worktree and branch kept"
say "PUSHED   sha=$(git -C "$primary" rev-parse --short main)"

git -C "$primary" worktree remove "$task"
git -C "$primary" branch -d "$branch" >/dev/null
say "CLEANED  worktree=$task branch=$branch"

# Runs from main's copy: the task's own .mine/ is gone once its worktree is removed.
"$primary/.mine/prune-derived.sh" --apply --worktree "$task" \
  || say "PRUNE    failed; run make prune-derived"
