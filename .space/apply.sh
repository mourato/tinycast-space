#!/bin/bash
# Applies every patch in .space/patches onto a pristine upstream checkout, in name order.
# --3way falls back to a merge when the context drifted, so only a real conflict fails.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
for patch in .space/patches/*.patch; do
  echo "applying ${patch##*/}"
  git apply --3way --whitespace=nowarn "$patch"
done

# Optional rewrites: wherever upstream links its releases page (the Changelog menu item and
# whatever comes next), point it here. Nothing to rewrite is not an error.
{ grep -rlF --include='*.swift' 'github.com/abue-ammar/tinycast/releases' Tinycast || true; } | while read -r file; do
  echo "rewriting releases link in $file"
  sed -i.bak 's#github\.com/abue-ammar/tinycast/releases#github.com/sermelipharo/tinycast-space/releases#g' "$file"
  rm -f "$file.bak"
done

# A patch to the extension runtime's sources only counts once the committed bundle is rebuilt from
# them. Upstream's build is deterministic, so an unpatched runtime would regenerate byte-identical.
if ! git diff --quiet HEAD -- Scripts/raycast-runtime/src; then
  echo "rebuilding the extension runtime bundle"
  (cd Scripts/raycast-runtime && npx --yes pnpm@10 install --frozen-lockfile --silent && node build.mjs)
fi

# The fork's own README; upstream's is kept verbatim beside it, marked as the original project's.
{
  printf '%s\n\n' "> **This is the original Tinycast README, kept verbatim.** Its install instructions, contact email, Discord and donation links belong to [abue-ammar/tinycast](https://github.com/abue-ammar/tinycast), not to this fork — see the fork's [README](README.md)."
  cat README.md
} > README.upstream.md
cp .space/README.fork.md README.md

# A patch that adds a source file needs it in the Xcode project. The project is generated from
# project.yml (upstream's own XcodeGen output is reproduced byte for byte), so regenerate instead
# of patching project.pbxproj, the file most likely to conflict.
if [ -n "$(git status --porcelain --untracked-files=all -- Tinycast | grep -E '^(\?\?|A ) ')" ]; then
  command -v xcodegen > /dev/null || brew install --quiet xcodegen
  echo "regenerating the Xcode project for added sources"
  xcodegen generate --quiet
fi

# The system-action harness pins the catalog's size to a literal, and patch 0007 adds one action.
# A rewrite rather than a patch hunk: upstream bumps that number whenever it adds an action, and a
# hunk on the same line would conflict every time.
if [ -f Tests/system-action-test.swift ]; then
  sed -i.bak -E 's/actions\.count == [0-9]+, "catalog contains all [0-9]+ agreed actions"/actions.count == SystemAction.ID.allCases.count, "catalog covers the agreed actions"/' \
    Tests/system-action-test.swift
  rm -f Tests/system-action-test.swift.bak
fi

# Patch 0011's theme core is read by Theme.swift, which several harnesses compile on their own, so
# list it beside Theme.swift wherever it appears. A rewrite: a harness upstream adds later is covered.
if [ -f Tinycast/Features/Settings/RaycastThemeCore.swift ]; then
  sed -i.bak 's#Tinycast/DesignSystem/Theme\.swift#& Tinycast/Features/Settings/RaycastThemeCore.swift#g' \
    Scripts/run-tests.sh
  rm -f Scripts/run-tests.sh.bak
fi

# Patch 0011 redraws themed colors through observation, which needs each ramp token computed on read
# rather than stored once: `static let x = ramp(…)` becomes `static var x: Color { ramp(…) }`. A
# rewrite, so upstream retuning or adding a token never conflicts with a hunk.
if [ -f Tinycast/Features/Settings/RaycastThemeCore.swift ]; then
  sed -E -i.bak 's/^( +)static let ([A-Za-z0-9_]+) = ramp\((.*)\)$/\1static var \2: Color { ramp(\3) }/' \
    Tinycast/DesignSystem/Theme.swift
  rm -f Tinycast/DesignSystem/Theme.swift.bak
fi
