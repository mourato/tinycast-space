#!/bin/bash
# Exports every commit since the `mine-base` tag to .mine/patches (one patch per commit) and commits
# the result, so patches survive a rebuild. Commits touching only .mine are not patches.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git rev-parse --quiet --verify mine-base > /dev/null || { echo "no mine-base tag yet" >&2; exit 0; }
rm -f .mine/patches/*.patch
git format-patch --quiet --zero-commit -N -o .mine/patches mine-base..HEAD -- . ':!.mine' ':!Makefile'
git add -A .mine/patches
git diff --cached --quiet || git commit --quiet -m "mine: save patches"
ls .mine/patches/*.patch 2> /dev/null || echo "no patches"
