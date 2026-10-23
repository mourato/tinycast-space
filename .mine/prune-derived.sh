#!/bin/bash
# Removes Xcode DerivedData left by deleted .worktrees/<slug> checkouts. Xcode keys each DerivedData
# folder by workspace path, so every task worktree leaves its own Tinycast Dev.app copy behind.
# Dry-run by default. Live worktrees and the main checkout are never matched. DERIVED_DATA_ROOT overrides
# the root, for tests.
set -euo pipefail

usage() {
  echo "Usage: prune-derived.sh [--apply] [--worktree ABSOLUTE_PATH]" >&2
}

apply=0
only=''
while (($#)); do
  case "$1" in
    --apply) apply=1; shift ;;
    --worktree)
      (($# >= 2)) || { usage; exit 2; }
      only=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

repo="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
root="${DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
[[ -d $root ]] || { echo "DONE     no DerivedData root: $root"; exit 0; }

planned=0
removed=0
kept=0
shopt -s nullglob
for dd in "$root"/Tinycast-*; do
  plist="$dd/info.plist"
  [[ -f $plist ]] || continue
  workspace="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$plist" 2>/dev/null || true)"
  [[ $workspace == "$repo/.worktrees/"*"/Tinycast.xcodeproj" ]] || continue
  slug=${workspace#"$repo/.worktrees/"}
  slug=${slug%/Tinycast.xcodeproj}
  [[ $slug =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || continue
  worktree="$repo/.worktrees/$slug"
  [[ -z $only || $only == "$worktree" ]] || continue
  if [[ -e $worktree ]]; then
    echo "KEEP     derived=$dd (worktree live)"
    kept=$((kept + 1))
    continue
  fi
  echo "REMOVE   derived=$dd worktree=$worktree (deleted)"
  planned=$((planned + 1))
  if ((apply)); then
    rm -rf "$dd"
    echo "REMOVED  derived=$dd"
    removed=$((removed + 1))
  fi
done
shopt -u nullglob

if ((apply)); then
  echo "DONE     removed=$removed kept=$kept"
else
  echo "DONE     planned_remove=$planned kept=$kept (dry-run; pass --apply to execute)"
fi
