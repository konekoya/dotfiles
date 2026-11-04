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
  */wiql\?*)
    printf '%s\n' "$body" > "$TEST_DIR/query.json"
    jq -n --argjson count "${TEST_COUNT:-2}" '{workItems: [range(1; $count + 1) | {id: .}]}'
    ;;
  */workitemsbatch\?*)
    if [ "${TEST_FAIL_BATCH:-}" = yes ]; then printf '\n503'; exit 0; fi
    if [ "${TEST_BAD_BATCH:-}" = yes ]; then printf '{"value":[]}\n200'; exit 0; fi
    printf '%s\n' "$body" | jq -c . >> "$TEST_DIR/batches.jsonl"
    printf '%s' "$body" | jq '{value: [.ids[] | {id: ., fields: {"System.WorkItemType": "Task", "System.Title": "Example", "System.State": "Active", "System.IterationPath": "Project\\Sprint"}}]}'
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
grep -q '^Iteration: @CurrentIteration$' "$TMP/out"
[ "$(wc -l < "$TMP/out" | tr -d ' ')" = 3 ]
jq -e '.query | contains("[System.IterationPath] = @CurrentIteration") and contains("NOT IN ('\''Closed'\'', '\''Done'\'', '\''Removed'\'', '\''Completed'\'', '\''Resolved'\'')")' "$TMP/query.json" >/dev/null
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
