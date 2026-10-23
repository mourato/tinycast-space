#!/bin/bash
# Regenerates main as: base + this fork's commits (.mine/patches, replayed with `git am -3`).
#   rebuild.sh space     base = sermelipharo/tinycast-space main (upstream + Space patches, CI-tested)
#   rebuild.sh upstream  base = newest abue-ammar/tinycast main + Space's .space patches applied here
# Your commits since the `mine-base` tag are exported to .mine/patches first, and the old main is
# kept as backup/main-<timestamp>. Space patches are preflighted before main moves; tooling is
# restored on every failure, so a rebuild never loses its own recovery commands.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
mode="${1:?usage: rebuild.sh space|upstream}"

[ -z "$(git status --porcelain)" ] || { echo "working tree dirty: commit or stash first" >&2; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "run on main" >&2; exit 1; }
[ -d .mine ] && [ -f Makefile ] || {
  echo "missing .mine or Makefile; restore backup/main-* before rebuilding" >&2
  exit 1
}

case "$mode" in
  space|upstream) ;;
  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac

tmp="$(mktemp -d)"
preflight_worktree=""
snapshot_ready=0
backup=""
rollback_main=0

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    if [ "$rollback_main" -eq 1 ] && [ -n "$backup" ]; then
      git reset --hard "$backup" >/dev/null 2>&1 || true
      echo "rebuild rolled back to $backup before patch replay" >&2
    fi
    if [ "$snapshot_ready" -eq 1 ]; then
      rm -rf .mine
      cp -R "$tmp/.mine" .mine
      cp "$tmp/Makefile" Makefile
      echo "restored .mine and Makefile after the failed rebuild" >&2
    fi
  fi
  if [ -n "$preflight_worktree" ]; then
    git worktree remove --force "$preflight_worktree" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT

preflight_space() {
  local upstream="$1"
  preflight_worktree="$tmp/space-preflight"
  git worktree add --quiet --detach "$preflight_worktree" space/main
  if [ ! -x "$preflight_worktree/.space/check-apply.sh" ]; then
    echo "space/main has no .space/check-apply.sh; cannot preflight safely" >&2
    return 1
  fi
  local report="$tmp/space-preflight.md"
  if ! "$preflight_worktree/.space/check-apply.sh" \
    "$upstream" "$(git show space/main:.space/UPSTREAM 2>/dev/null || true)" "$report"; then
    echo "Space patches do not apply cleanly; main was not changed" >&2
    [ -s "$report" ] && sed -n '1,120p' "$report" >&2
    return 1
  fi
  git worktree remove --force "$preflight_worktree" >/dev/null
  preflight_worktree=""
}

echo "fetching space and tinycast"
git fetch space
git fetch tinycast
if [ "$mode" = upstream ]; then
  up="$(git rev-parse tinycast/main)"
  echo "preflighting Space patches on upstream ${up:0:7}"
  preflight_space "$up"
fi

echo "saving patches"
"$(dirname "$0")/save-patches.sh"
cp -R .mine "$tmp/.mine"
cp Makefile "$tmp/Makefile"
snapshot_ready=1

backup="backup/main-$(date +%Y%m%d-%H%M%S)"
git show-ref --verify --quiet "refs/heads/$backup" && {
  echo "backup ref already exists: $backup; retry in another second" >&2
  exit 1
}
git branch "$backup"
rollback_main=1
echo "old main saved as $backup"

echo "rebuilding main on $mode"
case "$mode" in
  space)
    git reset --quiet --hard space/main ;;
  upstream)
    git reset --quiet --hard "$up"
    git checkout space/main -- .space .github/workflows
    .space/apply.sh
    echo "$up" > .space/UPSTREAM
    git add -A
    git commit --quiet -m "tinycast-space patches on upstream ${up:0:7} (local)" ;;
esac

rm -rf .mine; cp -R "$tmp/.mine" "$tmp/Makefile" .
git add -A .mine Makefile
git commit --quiet -m "mine: fork tooling"
git tag -f mine-base > /dev/null
rollback_main=0

shopt -s nullglob
patches=(.mine/patches/*.patch)
echo "replaying ${#patches[@]} patch(es)"
if [ ${#patches[@]} -gt 0 ] && ! git am -3 "${patches[@]}"; then
  echo "a patch conflicted: fix files, git add, then 'git am --continue' (then 'make save')." >&2
  echo "abort with 'git am --abort && git reset --hard $backup'" >&2
  exit 1
fi
echo "main = $(git log -1 --format=%s mine-base~1) + ${#patches[@]} patch(es)"
echo "push with: git push --force-with-lease origin main"
