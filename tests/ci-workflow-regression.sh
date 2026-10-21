#!/bin/bash
# Description: Regression coverage for the CI workflow triggers, concurrency, runner, and permissions
#
# The workflow is parsed as YAML and checked semantically, so key order, indentation, quoting and
# flow/block style do not matter. CI_WORKFLOW_FILE points the checks at another file (used to prove
# that altered workflows are rejected).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKFLOW="${CI_WORKFLOW_FILE:-$REPO_ROOT/.github/workflows/checks.yml}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

check_pass() { echo "PASS: $*"; }

[ -f "$WORKFLOW" ] || fail "missing $WORKFLOW"
command -v ruby > /dev/null || fail "ruby is required to parse the workflow (it ships with macOS)"
command -v jq > /dev/null || fail "jq is required"

# YAML 1.1 loads the bare key "on" as boolean true; map it back so quoting style does not matter.
WORKFLOW_JSON="$(ruby -ryaml -rjson -e '
  workflow = YAML.load_file(ARGV[0])
  abort "workflow is not a mapping" unless workflow.is_a?(Hash)
  workflow["on"] = workflow.delete(true) if workflow.key?(true)
  puts JSON.generate(workflow)
' "$WORKFLOW" 2> /dev/null)" || fail "workflow is not valid YAML"

# wf FILTER: succeed only when the jq filter is true for the parsed workflow.
wf() { jq -e "$1" <<< "$WORKFLOW_JSON" > /dev/null 2>&1; }

# Triggers: a PR commit must produce one run, and no filter may skip a required check.
wf '(.on | keys | sort) == ["pull_request", "push"]' \
  || fail "only push and pull_request may trigger the workflow"
wf '(.on.push | keys) == ["branches"] and (.on.pull_request | keys) == ["branches"]' \
  || fail "push and pull_request may only filter by branches (paths or types filters can skip a required check)"
wf 'def list: if type == "string" then [.] else . end;
    (.on.push.branches | list) == ["master"] and (.on.pull_request.branches | list) == ["master"]' \
  || fail "push and pull_request must both be limited to master (a PR commit would run twice otherwise)"
check_pass "push and pull_request are scoped to master with no other filters"

# Concurrency: one shared group per PR, a unique group for everything else.
wf '.concurrency | type == "object"' || fail "concurrency must be a top-level mapping"
wf '.concurrency.group | tostring | gsub("[[:space:]]"; "") | contains("github.event.pull_request.number||github.run_id")' \
  || fail "group must be the PR number, falling back to the unique run id"
check_pass "PR runs share a group; other runs fall back to the unique run id"

wf '.concurrency.group | tostring | test("github\\.(ref|head_ref|base_ref|sha)") | not' \
  || fail "group must not use a ref or sha: master pushes would share a group and replace pending checks"
check_pass "master pushes never share a concurrency group"

wf '.concurrency["cancel-in-progress"] | tostring | gsub("[[:space:]]"; "")
    | test("^\\$\\{\\{github\\.event_name==[^[:alnum:]_]pull_request[^[:alnum:]_]\\}\\}$")' \
  || fail "only pull_request runs may be cancelled; master runs must finish"
check_pass "only superseded pull_request runs are cancelled"

# macOS coverage and the job name that branch protection requires.
wf '.jobs.shell != null and ((.jobs.shell.name // "shell") == "shell")' \
  || fail "the job that branch protection requires must stay named shell"
wf '.jobs.shell["runs-on"] == "macos-latest"' || fail "the shell job must keep running on macos-latest"
check_pass "shell job runs on macos-latest"

# Permissions: read-only at every level, no secrets, no persisted checkout credentials.
wf '.permissions == {"contents": "read"}' || fail "workflow permissions must be exactly contents: read"
wf 'all(.jobs[]; (.permissions // {}) | type == "object" and all(.[]; . == "read" or . == "none"))' \
  || fail "no job may request more than read access"
wf 'tostring | test("secrets\\.") | not' || fail "the workflow must not reference secrets"
wf '[.jobs[].steps[]? | select((.uses // "") | test("^actions/checkout@"))]
    | length > 0 and all(.[]; .with["persist-credentials"] == false)' \
  || fail "every checkout step must set persist-credentials: false"
check_pass "permissions are read-only, with no secrets and no persisted credentials"

# Checks that must keep running.
wf '[.jobs[].steps[]?.run // empty] | join("\n") as $run
    | all(("/bin/bash -n", "zsh -n", "git diff --check",
           "shellcheck -S warning -x install.sh scripts/* lib/*.sh tests/*.sh",
           "for file in tests/*.sh", "/bin/bash \"$file\""); . as $needle | $run | contains($needle))' \
  || fail "syntax, whitespace, ShellCheck and regression-suite steps must all remain"
check_pass "syntax, whitespace, ShellCheck and all regression suites still run"

echo "CI workflow regression checks passed"
