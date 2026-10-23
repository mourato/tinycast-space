#!/bin/bash
# One open issue per blocked kind: `report.sh open <kind> <title> [<details.md> <cause>]` creates or
# comments, `report.sh close <kind>` closes it once a run goes through again.
# With a cause (the check job's patch conflicts), the same cause on a newer upstream only retitles the
# issue, so a conflict that waits for a fix notifies once instead of on every upstream commit. The
# title keeps its "upstream X + main Y" form: the check job and the timer on fradservice101 skip the
# combination it names.
set -euo pipefail
action="$1" kind="$2" label="space-$2"
run="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
gh label create "$label" --color d93f0b --description "tinycast-space automation" --force > /dev/null
num=$(gh issue list --label "$label" --state open --json number -q '.[0].number // empty')
if [ "$action" = open ]; then
  title="$3" details="${4:-}" cause="${5:-}"
  body="$title — see [the run log]($run). Nothing was published; \`main\` and the releases stay as they were until the patch in \`.space/patches\` is fixed."
  [ -n "$details" ] && body="$body"$'\n\n'"$(cat "$details")"
  [ -n "$cause" ] && body="$body"$'\n\n'"<!-- cause: $cause -->"
  if [ -n "$num" ] && [ -n "$cause" ] && gh issue view "$num" --json body -q .body | grep -qxF "<!-- cause: $cause -->"; then
    gh issue edit "$num" --title "$title" > /dev/null
  elif [ -n "$num" ]; then
    gh issue edit "$num" --title "$title" --body "$body" > /dev/null
    gh issue comment "$num" --body "$body"
  else
    gh issue create --title "$title" --label "$label" --body "$body"
  fi
elif [ -n "$num" ]; then
  gh issue close "$num" --comment "Went through in [this run]($run)."
fi
