#!/bin/bash
# Description: Regression checks for the local Copilot credit-to-TWD estimator
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/copilot-cost-regression.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/home"
cp "$REPO_ROOT/scripts/copilot-cost" "$TEST_ROOT/scripts/copilot-cost"
CLI="$TEST_ROOT/scripts/copilot-cost"

assert_estimate() {
  local expected="$1"
  shift
  local output
  output="$(env -u COPILOT_NTD_PER_CREDIT HOME="$TEST_ROOT/home" /bin/bash "$CLI" "$@")"
  [[ "$output" == *"Estimated: NT\$$expected"* ]] || {
    printf 'FAIL: expected NT$%s; got: %s\n' "$expected" "$output" >&2
    exit 1
  }
}

assert_fails() {
  if env -u COPILOT_NTD_PER_CREDIT HOME="$TEST_ROOT/home" /bin/bash "$CLI" "$@" >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"; then
    printf 'FAIL: unexpected success: %s\n' "$*" >&2
    exit 1
  fi
  [[ ! -s "$TEST_ROOT/out" ]] || { echo "FAIL: invalid input printed stdout" >&2; exit 1; }
}

assert_estimate 72.50 250
assert_estimate 72.25 250 --rate 0.289
assert_estimate 0.00 0
assert_estimate 0.15 0.5 --rate 0.30

output="$(COPILOT_NTD_PER_CREDIT=0.4 /bin/bash "$CLI" 250)"
[[ "$output" == *'Estimated: NT$100.00'* ]] || { echo "FAIL: env override" >&2; exit 1; }
output="$(COPILOT_NTD_PER_CREDIT=0.4 /bin/bash "$CLI" 250 --rate 0.2)"
[[ "$output" == *'Estimated: NT$50.00'* ]] || { echo "FAIL: CLI override precedence" >&2; exit 1; }

assert_fails
assert_fails -1
assert_fails abc
assert_fails 250 100
assert_fails 250 --rate
assert_fails 250 --rate -2
assert_fails 250 --rate 0
assert_fails 250 --rate invalid
assert_fails 250 --unknown
assert_fails '1;touch /tmp/not-allowed'
assert_fails 250 --rate '0.29;touch /tmp/not-allowed'

/bin/bash "$CLI" --help | grep -Fq 'Usage: copilot-cost'

echo "copilot-cost regression: passed"
