#!/bin/bash
# Signed Release build from .build/source. Xcode signs the bundle and its embedded helpers with the
# local certificate, so macOS keeps permissions across rebuilds. Identity: TINYCAST_SIGN_IDENTITY
# (name or SHA-1), default the first "Apple Development:" one. Prints the built app's path last.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$root/.mine/recipe.py" command build "$@"
