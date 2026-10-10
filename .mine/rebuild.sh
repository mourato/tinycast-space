#!/bin/bash
# Regenerates main as: base + this fork's commits (.mine/patches, replayed with `git am -3`).
#   rebuild.sh space     base = sermelipharo/tinycast-space main (upstream + Space patches, CI-tested)
#   rebuild.sh upstream  base = newest abue-ammar/tinycast main + Space's .space patches applied here
# Your commits since the `mine-base` tag are exported to .mine/patches first, and the old main is
# kept as backup/main-<timestamp>, so a rebuild never loses work.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
mode="${1:?usage: rebuild.sh space|upstream}"

[ -z "$(git status --porcelain)" ] || { echo "working tree dirty: commit or stash first" >&2; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "run on main" >&2; exit 1; }

"$(dirname "$0")/save-patches.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp -R .mine Makefile "$tmp/"

backup="backup/main-$(date +%Y%m%d-%H%M%S)"
git branch "$backup"
echo "old main saved as $backup"

git fetch --quiet space
git fetch --quiet tinycast
case "$mode" in
  space)
    git reset --quiet --hard space/main ;;
  upstream)
    up="$(git rev-parse tinycast/main)"
    git reset --quiet --hard "$up"
    git checkout space/main -- .space .github/workflows
    .space/apply.sh
    echo "$up" > .space/UPSTREAM
    git add -A
    git commit --quiet -m "tinycast-space patches on upstream ${up:0:7} (local)" ;;
  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac

rm -rf .mine; cp -R "$tmp/.mine" "$tmp/Makefile" .
git add -A .mine Makefile
git commit --quiet -m "mine: fork tooling"
git tag -f mine-base > /dev/null

shopt -s nullglob
patches=(.mine/patches/*.patch)
if [ ${#patches[@]} -gt 0 ] && ! git am --quiet -3 "${patches[@]}"; then
  echo "a patch conflicted: fix files, git add, then 'git am --continue' (then 'make save')." >&2
  echo "abort with 'git am --abort && git reset --hard $backup'" >&2
  exit 1
fi
echo "main = $(git log -1 --format=%s mine-base~1) + ${#patches[@]} patch(es)"
echo "push with: git push --force-with-lease origin main"
