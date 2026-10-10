#!/bin/bash
# Build + upstream's test suite. A failing harness blocks only if it keeps failing here and keeps
# passing on the pristine upstream commit, so upstream's own flaky or environment-bound harnesses
# never stall the sync.
# Usage: gate.sh <upstream-sha>
set -uo pipefail
UP="${1:?upstream sha}"
cd "$(git rev-parse --show-toplevel)"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"

echo "::group::xcodebuild"
if ! xcodebuild -project Tinycast.xcodeproj -scheme Tinycast -configuration Release \
  -derivedDataPath "$TMP/gate-dd" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build > "$TMP/gate-build.log" 2>&1; then
  echo "::endgroup::"
  grep -E 'error:' "$TMP/gate-build.log" | head -40
  tail -40 "$TMP/gate-build.log"
  echo "::error::build failed"
  exit 1
fi
echo "::endgroup::"

./Scripts/run-tests.sh 2>&1 | tee "$TMP/gate-tests.log"
failed=$(sed 's/\x1b\[[0-9;]*m//g' "$TMP/gate-tests.log" | sed -n 's/.*harness(es) failed in [0-9]*s: //p')
[ -z "$failed" ] && exit 0

# Upstream has timing-based harnesses (fixed sleeps around async work) that miss on a loaded runner.
# A harness only counts as broken by us if it fails every retry here and passes every run upstream.
retries=3
still=()
for t in $failed; do
  passed=0
  for _ in $(seq $retries); do ./Scripts/run-tests.sh "$t" > /dev/null 2>&1 && { passed=1; break; }; done
  [ $passed = 1 ] && echo "::warning::$t is flaky: failed in the full run, passed on a retry" || still+=("$t")
done
[ ${#still[@]} -eq 0 ] && exit 0

wt="$TMP/gate-upstream"
git worktree add --force --detach "$wt" "$UP" > /dev/null
regressions=()
for t in "${still[@]}"; do
  upstream_ok=1
  for _ in $(seq $retries); do
    (cd "$wt" && ./Scripts/run-tests.sh "$t" > /dev/null 2>&1) || { upstream_ok=0; break; }
  done
  if [ $upstream_ok = 1 ]; then
    regressions+=("$t")
  else
    echo "::warning::$t fails on upstream ${UP:0:7} too — not ours, ignored"
  fi
done
git worktree remove --force "$wt"
[ ${#regressions[@]} -eq 0 ] && exit 0
echo "::error::the patch breaks: ${regressions[*]}"
exit 1
