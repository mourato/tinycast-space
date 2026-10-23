#!/bin/bash
# Builds Release, signs it with the local certificate (.mine/build.sh) and replaces
# /Applications/Tinycast.app.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
app="/Applications/Tinycast.app"
built="$(.mine/build.sh | tail -1)"

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
