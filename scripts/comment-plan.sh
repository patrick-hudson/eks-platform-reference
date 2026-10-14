#!/usr/bin/env bash
set -euo pipefail
: "${TARGET:?}" "${GITHUB_REPOSITORY:?}" "${PR_NUMBER:?}" "${HEAD_SHA:?}" \
  "${GITHUB_SERVER_URL:?}" "${GITHUB_RUN_ID:?}" "${PLAN_JOB_STATUS:?}" "${PLAN_REPORT:?}" "${GH_TOKEN:?}"
case "$TARGET" in dev|prod) ;; *) echo "Invalid environment" >&2; exit 1 ;; esac
directory=$(mktemp -d)
trap 'rm -rf "$directory"' EXIT
marker="<!-- terraform-plan:$TARGET -->"
{
  printf '%s\n### Terraform plan: %s\n\n' "$marker" "$TARGET"
  printf 'Job result: **%s**. Commit: `%s`. [Workflow run](%s/%s/actions/runs/%s).\n\n' \
    "$PLAN_JOB_STATUS" "$HEAD_SHA" "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  if [[ -s "$PLAN_REPORT" ]]; then
    cat "$PLAN_REPORT"
    printf '\nReplacements also count toward Add and Destroy. Counts describe managed resources; output-only changes are not included.\n'
    printf '\nA deferred monitoring plan requires an existing cluster. Check the workflow logs for any failure or incomplete results.\n'
  else
    printf 'No plan results were produced. Check the workflow logs.\n'
  fi
} > "$directory/comment.md"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$directory/comment.md" >> "$GITHUB_STEP_SUMMARY"
fi
jq -n --rawfile body "$directory/comment.md" '{body: $body}' > "$directory/payload.json"
comments=$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments")
comment_id=$(jq -r --arg marker "$marker" '
  [.[][] | select(.user.login == "github-actions[bot]" and ((.body // "") | startswith($marker)))] |
  sort_by(.id) | last | .id // empty
' <<< "$comments")
if [[ -n "$comment_id" ]]; then
  gh api --method PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$comment_id" --input "$directory/payload.json" --silent
else
  gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" --input "$directory/payload.json" --silent
fi
