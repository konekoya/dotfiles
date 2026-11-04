#!/bin/bash
# Description: Regression coverage for the Azure DevOps work item query command
set -euo pipefail

trap 'printf "FAIL at line %s\n" "$LINENO" >&2' ERR
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ado-tasks-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/dotfiles/scripts" "$TMP/dotfiles/lib" "$TMP/bin" "$TMP/repo"
cp "$ROOT/scripts/ado-tasks" "$TMP/dotfiles/scripts/"
cp "$ROOT"/lib/*.sh "$TMP/dotfiles/lib/"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG GIT_CONFIG_COUNT AZURE_DEVOPS_ORG AZURE_DEVOPS_PAT
export AZURE_DEVOPS_PAT_TEST='synthetic-test-token'
export TEST_DIR="$TMP"
export PATH="$TMP/bin:$PATH"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" remote add origin https://dev.azure.com/example/project/_git/repo
git -C "$TMP/repo" config azure-devops.profile test
git -C "$TMP/repo" config azure-devops.test.organization example
cd "$TMP/repo"
CLI="$TMP/dotfiles/scripts/ado-tasks"

query_has() {
  jq -r '.query' "$TMP/query.json" | grep -Fq "$1"
}

cat > "$TMP/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
url=""
body=""
header_seen=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H)
      case "$2" in
        @/dev/fd/3) [ -p /dev/fd/3 ]; cat /dev/fd/3 >/dev/null; header_seen=true ;;
        *synthetic-test-token*|Authorization:*) exit 9 ;;
      esac
      shift 2 ;;
    -d) body="$2"; shift 2 ;;
    -X|--connect-timeout|--max-time|-w) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ "$header_seen" = true ]
if [ "${TEST_FAIL:-}" = yes ]; then printf '\n500'; exit 0; fi
case "$url" in
  */workitemtypes\?*)
    printf 'types\n' >> "$TEST_DIR/requests.log"
    if [ "${TEST_STATES_FAIL:-}" = yes ]; then printf '\n503'; exit 0; fi
    if [ "${TEST_STATES_MISSING_CATEGORY:-}" = yes ]; then
      jq -n '{value: [{name: "Task", states: [{name: "Rejected"}, {name: "Active", category: "Proposed"}]}]}'
    elif [ "${TEST_STATES_EMPTY_EXCLUSIONS:-}" = yes ]; then
      jq -n '{value: [{name: "Task", states: [{name: "Active", category: "Proposed"}]}, {name: "Bug", states: [{name: "Waiting", category: "InProgress"}]}]}'
    elif [ "${TEST_STATES_PER_TYPE:-}" = yes ]; then
      jq -n '{value: [{name: "Task", states: [{name: "Waiting QA", category: "Resolved"}, {name: "Closed", category: "Completed"}, {name: "Active", category: "InProgress"}]}, {name: "Bug", states: [{name: "Waiting QA", category: "InProgress"}, {name: "Closed", category: "InProgress"}]}, {name: "Epic", states: [{name: "Done", category: "Completed"}]}, {name: "Feature", states: [{name: "Proposed", category: "Proposed"}]}]}'
    elif [ "${TEST_STATES_APOSTROPHE:-}" = yes ]; then
      jq -n '{value: [{name: "O\u0027Brien", states: [{name: "Owner\u0027s Done", category: "Completed"}]}]}'
    else
      jq -n '{value: [{name: "Task", states: [{name: "Active", category: "Proposed"}, {name: "Rejected", category: "Completed"}, {name: "Removed", category: "Removed"}]}]}'
    fi
    ;;
  */teamsettings/iterations\?*)
    printf '%s' "$url" > "$TEST_DIR/current-url"
    [ "$url" = 'https://dev.azure.com/example/project/_apis/work/teamsettings/iterations?api-version=7.1&timeframe=current' ] || exit 11
    if [ "${TEST_CURRENT_FAIL:-}" = yes ]; then printf '\n503'; exit 0; fi
    if [ "${TEST_CURRENT_BAD_SHAPE:-}" = yes ]; then
      jq -n '{value: [{name: "Sprint"}]}'
    elif [ "${TEST_NO_CURRENT:-}" = yes ]; then
      jq -n '{value: []}'
    else
      jq -n '{value: [{name: "Sprint", path: "Project\\Sprint", attributes: {timeFrame: "current"}}]}'
    fi
    ;;
  */wiql\?*)
    printf '%s\n' "$body" > "$TEST_DIR/query.json"
    jq -n --argjson count "${TEST_COUNT:-2}" '{workItems: [range(1; $count + 1) | {id: .}]}'
    ;;
  */workitemsbatch\?*)
    if [ "${TEST_FAIL_BATCH:-}" = yes ]; then printf '\n503'; exit 0; fi
    if [ "${TEST_BAD_BATCH:-}" = yes ]; then printf '{"value":[]}\n200'; exit 0; fi
    printf '%s\n' "$body" | jq -c . >> "$TEST_DIR/batches.jsonl"
    printf '%s' "$body" | jq --arg title "${MOCK_TITLE:-Example}" '{value: [.ids[] | {id: ., fields: {"System.WorkItemType": "Task", "System.Title": $title, "System.State": "Active", "System.IterationPath": "Project\\Sprint"}}]}'
    ;;
  *) exit 10 ;;
esac
printf '\n200'
MOCK
chmod +x "$TMP/bin/curl"

"$CLI" --iteration "Project\\Sprint's" --state "In Progress" --state "Owner's Review" --type Task --type Bug --json > "$TMP/out"
jq -e '.iteration == "Project\\Sprint\u0027s" and (.items | length == 2) and .items[0] == {id:1,type:"Task",title:"Example",state:"Active",iteration:"Project\\Sprint"}' "$TMP/out" >/dev/null
jq -e '.query | contains("[System.TeamProject] = @project") and contains("[System.AssignedTo] = @Me") and contains("[System.IterationPath] = '\''Project\\Sprint'\'''\''s'\''") and contains("[System.State] IN ('\''In Progress'\'', '\''Owner'\'''\''s Review'\'')") and contains("[System.WorkItemType] IN ('\''Task'\'', '\''Bug'\'')") and (contains("NOT IN") | not)' "$TMP/query.json" >/dev/null
"$CLI" --current > "$TMP/out"
grep -q '^Iteration: Project\\Sprint$' "$TMP/out"
[ "$(cat "$TMP/current-url")" = 'https://dev.azure.com/example/project/_apis/work/teamsettings/iterations?api-version=7.1&timeframe=current' ]
[ "$(wc -l < "$TMP/out" | tr -d ' ')" = 3 ]
query_has '[System.IterationPath] = @CurrentIteration'
query_has "[System.WorkItemType] <> 'Task'"
query_has "[System.State] NOT IN ('Rejected', 'Removed')"
[ "$(cat "$TMP/requests.log")" = types ]
"$CLI" --current --json > "$TMP/out"
jq -e '.iteration == "Project\\Sprint"' "$TMP/out" >/dev/null
TEST_COUNT=0 TEST_NO_CURRENT=yes "$CLI" --current > "$TMP/out" 2> "$TMP/err"
grep -q '^Iteration: @CurrentIteration$' "$TMP/out"
grep -q 'no current iteration configured; use --iteration <path>' "$TMP/err"
if grep -qi 'could not resolve' "$TMP/err"; then exit 1; fi
TEST_COUNT=0 TEST_CURRENT_FAIL=yes "$CLI" --current > "$TMP/out" 2> "$TMP/err"
grep -q 'Could not resolve the team current iteration; use --iteration <path>' "$TMP/err"
if grep -q 'no current iteration configured' "$TMP/err"; then exit 1; fi
TEST_COUNT=0 TEST_CURRENT_BAD_SHAPE=yes "$CLI" --current > "$TMP/out" 2> "$TMP/err"
grep -q 'Could not resolve the team current iteration; use --iteration <path>' "$TMP/err"
TEST_STATES_FAIL=yes "$CLI" --iteration 'Project\Sprint' > "$TMP/out"
query_has "[System.State] NOT IN ('Closed', 'Done', 'Removed', 'Completed', 'Rejected')"
if query_has 'Resolved'; then exit 1; fi
TEST_STATES_MISSING_CATEGORY=yes "$CLI" --iteration 'Project\Sprint' > "$TMP/out"
query_has "[System.State] NOT IN ('Closed', 'Done', 'Removed', 'Completed', 'Rejected')"
TEST_STATES_EMPTY_EXCLUSIONS=yes "$CLI" --iteration 'Project\Sprint' > "$TMP/out"
query_has "[System.State] NOT IN ('Closed', 'Done', 'Removed', 'Completed', 'Rejected')"
TEST_STATES_PER_TYPE=yes "$CLI" --iteration 'Project\Sprint' > "$TMP/out"
query_has "([System.WorkItemType] <> 'Task' OR [System.State] NOT IN ('Closed')) AND ([System.WorkItemType] <> 'Epic' OR [System.State] NOT IN ('Done'))"
if query_has "Waiting QA" || query_has "[System.WorkItemType] <> 'Bug'" || query_has "[System.WorkItemType] <> 'Feature'" || query_has "[System.WorkItemType] <> 'Missing'"; then exit 1; fi
TEST_STATES_APOSTROPHE=yes "$CLI" --iteration 'Project\Sprint' > "$TMP/out"
query_has "[System.WorkItemType] <> 'O''Brien'"
query_has "[System.State] NOT IN ('Owner''s Done')"
TEST_COUNT=1 "$CLI" --iteration 'Project\Sprint' > "$TMP/out"
[ "$(sed -n '1p' "$TMP/out")" = 'Iteration: Project\Sprint' ]
[ "$(sed -n '2p' "$TMP/out" | cut -f5)" = 'Project\Sprint' ]
[ "$(sed -n '2p' "$TMP/out" | awk -F '\t' '{print NF}')" = 5 ]
TEST_COUNT=1 MOCK_TITLE=$'first\tsecond\nthird' "$CLI" --iteration 'Project\Sprint' > "$TMP/out"
[ "$(wc -l < "$TMP/out" | tr -d ' ')" = 2 ]
[ "$(sed -n '2p' "$TMP/out" | awk -F '\t' '{print NF}')" = 5 ]
rm -f "$TMP/batches.jsonl"
TEST_COUNT=0 "$CLI" --current --json > "$TMP/out"
jq -e '.items == []' "$TMP/out" >/dev/null
[ ! -e "$TMP/batches.jsonl" ]
TEST_COUNT=201 "$CLI" --current --json > "$TMP/out"
jq -e '.items | length == 201' "$TMP/out" >/dev/null
[ "$(wc -l < "$TMP/batches.jsonl" | tr -d ' ')" = 2 ]
jq -s -e 'map(.ids | length) == [200, 1]' "$TMP/batches.jsonl" >/dev/null
if AZURE_DEVOPS_ORG=other "$CLI" --current > "$TMP/out" 2>&1; then exit 1; fi
grep -q 'does not match' "$TMP/out"
if TEST_FAIL=yes "$CLI" --current > "$TMP/out" 2>&1; then exit 1; fi
grep -q 'HTTP 500' "$TMP/out"
if TEST_FAIL_BATCH=yes "$CLI" --current > "$TMP/out" 2>&1; then exit 1; fi
grep -q 'HTTP 503' "$TMP/out"
if TEST_BAD_BATCH=yes "$CLI" --current > "$TMP/out" 2>&1; then exit 1; fi
grep -q 'invalid work item details' "$TMP/out"
for args in '' '--current --iteration path' '--state' '--iteration path --type'; do
  # Intentional splitting supplies a small fixed set of invalid argument combinations.
  # shellcheck disable=SC2086
  if "$CLI" $args > "$TMP/out" 2>&1; then exit 1; fi
done
printf 'ado-tasks regression: passed\n'
