#!/bin/bash
# Exports every commit since the `mine-base` tag to .mine/patches (one patch per commit) and commits
# the result, so patches survive a rebuild. Commits touching only .mine are not patches. The current
# patch directory is replaced only after format-patch succeeds.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git rev-parse --quiet --verify mine-base > /dev/null || { echo "no mine-base tag yet" >&2; exit 0; }
export_dir="$(mktemp -d)"
patch_dir=".mine/patches"

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -d "$export_dir/previous" ]; then
    rm -rf "$patch_dir"
    mv "$export_dir/previous" "$patch_dir"
  fi
  rm -rf "$export_dir"
  exit "$status"
}
trap cleanup EXIT

git format-patch --quiet --zero-commit -N -o "$export_dir" mine-base..HEAD -- . ':!.mine' ':!Makefile'

staged_dir="$export_dir/patches"
cp -R "$patch_dir" "$staged_dir"
rm -f "$staged_dir"/*.patch
cp "$export_dir"/*.patch "$staged_dir"/ 2>/dev/null || true
mv "$patch_dir" "$export_dir/previous"
mv "$staged_dir" "$patch_dir"

git add -A .mine/patches
git diff --cached --quiet || git commit --quiet -m "mine: save patches"
ls .mine/patches/*.patch 2> /dev/null || echo "no patches"
