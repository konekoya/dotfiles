# shellcheck shell=bash
# GitHub list/status implementation, sourced only after selected-remote validation.

pr_github_error() {
  echo '❌ GitHub request failed or returned malformed/incomplete data.' >&2
  return 1
}

pr_github_require() {
  local cmd
  for cmd in jq gh-auth; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "❌ '$cmd' is required for GitHub PRs." >&2
      return 1
    }
  done
}

# All requests are read-only and repository-bound; never relay CLI diagnostics.
pr_github_read() {
  local response
  response=$(gh-auth pr "$@" --repo "$GITHUB_OWNER/$GITHUB_REPO" 2>/dev/null) || {
    pr_github_error
    return 1
  }
  printf '%s' "$response" | jq -e -s 'length == 1' >/dev/null 2>&1 || {
    pr_github_error
    return 1
  }
  printf '%s' "$response"
}

# External display strings are selected explicitly, stripped of terminal controls and URLs.
PR_GITHUB_TEXT='def text: gsub("\u001b\\[[0-?]*[ -/]*[@-~]"; "")
  | gsub("[[:cntrl:]]"; "") | gsub("(?i)(https?://|ssh://|git@)[^[:space:]]+"; "[url]");'

pr_github_list() {
  pr_github_require || return
  local authored reviews data heading
  authored=$(pr_github_read list --state open --author @me --limit 1000 \
    --json number,title,author,headRefName,baseRefName) || return
  reviews=$(pr_github_read list --state open --search review-requested:@me --limit 1000 \
    --json number,title,author,headRefName,baseRefName) || return
  for data in "$authored" "$reviews"; do
    printf '%s' "$data" | jq -e 'type == "array" and length < 1000 and all(.[];
      type == "object" and (.number | type == "number" and . > 0 and floor == .)
      and (.title | type == "string") and (.author.login | type == "string")
      and (.headRefName | type == "string") and (.baseRefName | type == "string"))' \
      >/dev/null 2>&1 || { pr_github_error; return 1; }
  done
  for heading in 'Created by me' 'Awaiting my review'; do
    if [ "$heading" = 'Created by me' ]; then data="$authored"; else data="$reviews"; fi
    printf '\n%s (%s)\n' "$heading" "$(printf '%s' "$data" | jq length)"
    printf '%s' "$data" | jq -r "$PR_GITHUB_TEXT"'
      if length == 0 then "  (none)" else .[] |
      "  #\(.number)  \(.title | text)\n  \(.headRefName | text) → \(.baseRefName | text)  · \(.author.login | text)" end'
  done
}

pr_github_status() {
  local watch=false json=false interval=20 pr_id='' branch matches count
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --watch) watch=true; shift ;;
      --json) json=true; shift ;;
      --interval)
        if [ "$#" -lt 2 ] || [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
          echo '❌ --interval requires a positive number of seconds.' >&2
          return 2
        fi
        interval="$2"; shift 2 ;;
      *)
        if [[ ! "$1" =~ ^[1-9][0-9]*$ ]] || [ -n "$pr_id" ]; then
          echo 'Usage: pr status [ID] [--watch] [--interval SECONDS] [--json]' >&2
          return 2
        fi
        pr_id="$1"; shift ;;
    esac
  done
  if [ "$json" = true ] && [ "$watch" = true ]; then
    echo '❌ --json cannot be combined with --watch.' >&2
    return 2
  fi
  pr_github_require || return
  if [ -z "$pr_id" ]; then
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || {
      echo '❌ Not on a named branch. Pass an ID: pr status <ID>' >&2
      return 1
    }
    matches=$(pr_github_read list --state open --head "$branch" --limit 1000 \
      --json number,headRefName,headRepository,headRepositoryOwner,isCrossRepository) || return
    printf '%s' "$matches" | jq -e 'type == "array" and length < 1000 and all(.[];
      type == "object" and (.number | type == "number" and . > 0 and floor == .)
      and (.headRefName | type == "string") and (.isCrossRepository | type == "boolean")
      and (.headRepository.name | type == "string") and (.headRepositoryOwner.login | type == "string"))' \
      >/dev/null 2>&1 || { pr_github_error; return 1; }
    matches=$(printf '%s' "$matches" | jq -c --arg branch "$branch" \
      --arg owner "$GITHUB_OWNER" --arg repo "$GITHUB_REPO" '
      map(select(.headRefName == $branch and
        (.headRepository.name | ascii_downcase) == ($repo | ascii_downcase) and
        (.headRepositoryOwner.login | ascii_downcase) == ($owner | ascii_downcase)))')
    count=$(printf '%s' "$matches" | jq length)
    if [ "$count" -ne 1 ]; then
      echo '❌ Expected exactly one open PR for this branch in the selected source repository.' >&2
      echo 'Fork PRs in another base repository require selecting that repository and passing an ID; no upstream is guessed.' >&2
      return 1
    fi
    pr_id=$(printf '%s' "$matches" | jq -r '.[0].number')
  fi
  local deadline=$((SECONDS + 540)) state
  while true; do
    pr_github_snapshot || return
    if [ "$watch" != true ] || { [ "$state" != pending ] && [ "$state" != none ]; }; then
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "⏳ Still pending after ~9 minutes of watching — run 'pr status --watch' again to keep going."
      return 0
    fi
    echo "⏳ pending — rechecking in ${interval}s..."
    sleep "$interval"
  done
}

# Dynamically scoped status locals keep each watch snapshot tied to the requested ID.
pr_github_snapshot() {
  local data normalized
  data=$(pr_github_read view "$pr_id" --json number,title,state,headRefOid,statusCheckRollup,reviewDecision) || return
  printf '%s' "$data" | jq -e --arg id "$pr_id" '
    type == "object" and .number == ($id | tonumber) and (.title | type == "string")
    and (.state == "OPEN" or .state == "CLOSED" or .state == "MERGED")
    and (.headRefOid | type == "string" and test("^[0-9a-fA-F]{40,64}$"))
    and (.reviewDecision == null or (.reviewDecision | type == "string"))
    and has("statusCheckRollup") and (.statusCheckRollup == null or
      (.statusCheckRollup | type == "array" and all(.[]; type == "object")))' \
    >/dev/null 2>&1 || { pr_github_error; return 1; }
  normalized=$(printf '%s' "$data" | jq -c '
    def mapped:
      if .__typename == "CheckRun" then
        if .status == "COMPLETED" then
          if .conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED" then "succeeded"
          elif .conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT" or .conclusion == "ACTION_REQUIRED" or .conclusion == "STARTUP_FAILURE" then "failed"
          else "unknown" end
        elif .status == "QUEUED" or .status == "IN_PROGRESS" or .status == "WAITING" or .status == "REQUESTED" or .status == "PENDING" then "pending"
        else "unknown" end
      elif .__typename == "StatusContext" then
        if .state == "SUCCESS" then "succeeded"
        elif .state == "ERROR" or .state == "FAILURE" then "failed"
        elif .state == "EXPECTED" or .state == "PENDING" then "pending"
        else "unknown" end
      else "unknown" end;
    [(.statusCheckRollup // [])[] | {state: mapped, buildId: null}] as $checks
    | {checks: $checks, state:
      (if any($checks[]; .state == "failed") then "failed"
       elif any($checks[]; .state != "succeeded") then "pending"
       elif ($checks | length) == 0 then "none" else "succeeded" end)}' 2>/dev/null) \
    || { pr_github_error; return 1; }
  state=$(printf '%s' "$normalized" | jq -r .state)
  if [ "$json" = true ]; then
    printf '%s' "$normalized" | jq -c --arg id "$pr_id" --arg owner "$GITHUB_OWNER" --arg repo "$GITHUB_REPO" \
      '{pullRequestId: ($id | tonumber), organization: $owner, project: null,
        repository: $repo, state: .state, checks: .checks}'
  else
    printf '%s' "$data" | jq -r "$PR_GITHUB_TEXT"'
      "\nPR #\(.number)  \(.title | text)\nHead: \(.headRefOid)\nReview: \((.reviewDecision // "unknown") | text)"'
    printf 'CI: %s (not a merge-readiness claim)\n' "$state"
    printf '%s' "$normalized" | jq -r '.checks[] | "  " + .state'
  fi
}
