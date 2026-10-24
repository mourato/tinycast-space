#!/bin/bash
# Builds Release, signed with the local certificate (.mine/recipe.py command build) and replaces
# /Applications/Tinycast.app. A failed build stops before anything is quit or replaced.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="/Applications/Tinycast.app"
built="$(python3 "$root/.mine/recipe.py" command build | tail -1)"

case "$built" in
  "$root"/.build/DerivedData/Build/Products/Release/Tinycast.app) ;;
  *) echo "unexpected build artifact: ${built:-none}" >&2; exit 1 ;;
esac

echo "quitting running Tinycast"
osascript -e 'quit app id "com.tinycast.app"' 2> /dev/null || true
for _ in $(seq 30); do pgrep -xq Tinycast || break; sleep 0.5; done
pgrep -xq Tinycast && { echo "Tinycast still running, quit it and retry" >&2; exit 1; }

echo "replacing $app"
rm -rf "$app"
ditto "$built" "$app"
echo "launching Tinycast"
open "$app"
echo "installed $app"
