#!/bin/bash
# Replaces /Applications/Tinycast.app with the signed Release product built by recipe.py, which owns
# the operation lock and passes the artifact path. A failed build never reaches this script.
set -euo pipefail
built="${1:?usage: install.sh <signed Release app>}"
app="/Applications/Tinycast.app"

[ -d "$built" ] || { echo "missing build artifact: $built" >&2; exit 1; }

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
