#!/bin/bash
# One open issue per blocked kind: `report.sh open <kind> <title>` creates or comments,
# `report.sh close <kind>` closes it once a run goes through again.
set -euo pipefail
action="$1" kind="$2" label="space-$2"
run="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
gh label create "$label" --color d93f0b --description "tinycast-space automation" --force > /dev/null
num=$(gh issue list --label "$label" --state open --json number -q '.[0].number // empty')
if [ "$action" = open ]; then
  body="$3 — see [the run log]($run). Nothing was published; \`main\` and the releases stay as they were until the patch in \`.space/patches\` is fixed."
  if [ -n "$num" ]; then
    gh issue edit "$num" --title "$3" > /dev/null
    gh issue comment "$num" --body "$body"
  else
    gh issue create --title "$3" --label "$label" --body "$body"
  fi
elif [ -n "$num" ]; then
  gh issue close "$num" --comment "Went through in [this run]($run)."
fi
