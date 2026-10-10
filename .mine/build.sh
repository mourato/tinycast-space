#!/bin/bash
# Release build, re-signed with the local certificate so macOS keeps permissions across rebuilds.
# Identity: TINYCAST_SIGN_IDENTITY (name or SHA-1), default the first "Apple Development:" one,
# as in the other local projects. Prints the built app's path last.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
dd="$HOME/Library/Developer/Xcode/DerivedData/tinycast-mine"
requested="${TINYCAST_SIGN_IDENTITY:-Apple Development}"

# Resolve to a SHA-1: two certificates can share a name, which codesign rejects as ambiguous.
identity="$(security find-identity -v -p codesigning \
  | awk -v want="$requested" '{ hash = $2; $1 = $2 = ""; name = substr($0, 3); gsub(/"/, "", name)
      if (hash == want || name == want || index(name, want ":") == 1) { print hash; exit } }')"
[ -n "$identity" ] || { echo "no codesigning identity matches '$requested'" >&2; exit 1; }

log="$(mktemp -t tinycast-build)"
xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Release \
  -derivedDataPath "$dd" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  PRODUCT_NAME="Tinycast" PRODUCT_BUNDLE_IDENTIFIER="com.tinycast.app" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build > "$log" 2>&1 \
  || { grep -E 'error:' "$log" | head -30; echo "build failed, log: $log" >&2; exit 1; }
app="$dd/Build/Products/Release/Tinycast.app"

codesign --force --deep --timestamp=none --preserve-metadata=entitlements,requirements,flags \
  --sign "$identity" "$app" >&2
codesign --verify --deep --strict "$app" >&2
echo "signed with $identity" >&2
echo "$app"
