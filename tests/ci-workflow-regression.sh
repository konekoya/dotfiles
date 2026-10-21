#!/bin/bash
# Description: Regression coverage for the CI workflow triggers, concurrency, runner, and permissions

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKFLOW="$REPO_ROOT/.github/workflows/checks.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

check_pass() { echo "PASS: $*"; }

[ -f "$WORKFLOW" ] || fail "missing $WORKFLOW"

# The trigger block collapsed to one token string, so key order and values are compared exactly.
triggers="$(awk '/^on:/{found=1; next} /^[^ #]/{found=0} found && !/^[[:space:]]*#/' "$WORKFLOW" | tr -d ' \n')"
[ "$triggers" = "push:branches:[master]pull_request:branches:[master]" ] \
  || fail "push and pull_request must both be limited to master (a PR commit would run twice otherwise)"
check_pass "push and pull_request are scoped to master"

grep -Fqx '  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}' "$WORKFLOW" \
  || fail "concurrency group must key on the PR number or the ref"
check_pass "concurrency group is per PR or per ref"

grep -Fqx "  cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$WORKFLOW" \
  || fail "only pull_request runs may be cancelled; master runs must finish"
check_pass "only superseded PR runs are cancelled"

grep -Eqx '    runs-on: macos-latest' "$WORKFLOW" || fail "the shell job must keep running on macOS"
check_pass "shell job runs on macos-latest"

grep -Eqx '  contents: read' "$WORKFLOW" || fail "workflow permissions must stay read-only"
check_pass "permissions are read-only"

grep -Fq 'shellcheck -S warning -x install.sh scripts/* lib/*.sh tests/*.sh' "$WORKFLOW" \
  || fail "ShellCheck step is missing"
grep -Fq 'for file in tests/*.sh; do' "$WORKFLOW" || fail "regression suites are no longer run"
check_pass "ShellCheck and all regression suites still run"

echo "CI workflow regression checks passed"
