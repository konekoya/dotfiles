#!/bin/bash
# Description: Regression coverage for start-work notes synchronization boundaries

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/start-work-regression.XXXXXX")" || exit 1
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)" || exit 1
TEST_BIN="$TEST_ROOT/bin"
NOTES_FIXTURE="$TEST_ROOT/notes"
mkdir -p "$TEST_BIN" "$NOTES_FIXTURE" || exit 1

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

awk '
  /^```bash$/ && !inside { inside = 1; next }
  inside && /^```$/ { exit }
  inside { print }
' "$REPO_ROOT/skills/start-work/SKILL.md" > "$TEST_ROOT/notes-sync.sh" || fail "could not extract notes sync instructions"
[ -s "$TEST_ROOT/notes-sync.sh" ] || fail "notes sync code block is missing"

cat > "$TEST_BIN/local-env" <<'EOF'
#!/bin/bash
WORK_NOTES_DIR="${NOTES_FIXTURE:?}"
EOF
cat > "$TEST_BIN/git" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GIT_CALLS"
[ "${1:-}" = "-C" ] || exit 90
shift 2
case "${1:-}" in
  rev-parse)
    case "${2:-}" in
      --is-inside-work-tree) [ "${SCENARIO:-}" != missing ] ;;
      --verify) [ "${BRANCH_NAME:-}" != no-origin ] ;;
      HEAD) printf 'before-hash\n' ;;
      *) exit 91 ;;
    esac
    ;;
  status)
    [ "${SCENARIO:-}" = pull-failed ] && printf ' M board.md\n'
    ;;
  branch) printf '%s\n' "${BRANCH_NAME:-main}" ;;
  pull) [ "${SCENARIO:-}" != pull-failed ] ;;
  log) printf 'after-hash pulled summary\n' ;;
  rev-list) printf '4\n' ;;
  *) exit 92 ;;
esac
EOF
chmod +x "$TEST_BIN/local-env" "$TEST_BIN/git" || fail "could not prepare command mocks"

run_sync() {
  : > "$TEST_ROOT/git-calls"
  if PATH="$TEST_BIN" \
    NOTES_FIXTURE="$NOTES_FIXTURE" \
    GIT_CALLS="$TEST_ROOT/git-calls" \
    SCENARIO="${SCENARIO:-}" \
    BRANCH_NAME="${BRANCH_NAME:-main}" \
    /bin/bash "$TEST_ROOT/notes-sync.sh" > "$TEST_ROOT/output" 2>&1; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}

SCENARIO=missing
BRANCH_NAME=main
run_sync
[ "$RUN_STATUS" -eq 0 ] || fail "missing notes did not stop cleanly"
grep -Fxq missing "$TEST_ROOT/output" || fail "missing notes were not reported"
[ "$(wc -l < "$TEST_ROOT/git-calls" | tr -d ' ')" -eq 1 ] || fail "missing notes continued to later Git commands"

SCENARIO=main-pull
BRANCH_NAME=main
run_sync
[ "$RUN_STATUS" -eq 0 ] || fail "main pull scenario failed"
grep -Fq 'pulled' "$TEST_ROOT/output" || fail "successful pull was not reported"
grep -Fq 'after-hash pulled summary' "$TEST_ROOT/output" || fail "pulled commits were not summarized"
grep -Fq 'pull --rebase --autostash --quiet' "$TEST_ROOT/git-calls" || fail "main did not use the authorized pull"

SCENARIO=pull-failed
BRANCH_NAME=main
run_sync
[ "$RUN_STATUS" -eq 0 ] || fail "failed pull scenario did not stop cleanly"
grep -Fq 'pull failed' "$TEST_ROOT/output" || fail "failed pull was not reported"
grep -Fq 'status --short' "$TEST_ROOT/git-calls" || fail "failed pull did not report notes status"

SCENARIO=notes-branch
BRANCH_NAME=notes/session
run_sync
[ "$RUN_STATUS" -eq 0 ] || fail "notes branch scenario failed"
grep -Fq 'origin/main commits not in it: 4' "$TEST_ROOT/output" || fail "notes branch did not report its missing commit count"
if grep -Eq '(^| )((pull)|(fetch)|(switch)|(rebase))( |$)' "$TEST_ROOT/git-calls"; then
  fail "notes branch changed Git state"
fi

SCENARIO=no-origin
BRANCH_NAME=no-origin
run_sync
grep -Fq 'origin/main is not available locally' "$TEST_ROOT/output" || fail "missing origin/main was not reported"

SKILL="$REPO_ROOT/skills/start-work/SKILL.md"
grep -Fq 'snapshot --since <date>' "$SKILL" || fail "ClickUp snapshot does not specify a date"
grep -Fq 'date seven days ago' "$SKILL" || fail "ClickUp fallback window is not documented"
grep -Fq 'ado-tasks` from inside the project repository' "$SKILL" || fail "Azure DevOps repository context is not documented"
grep -Fq 'ado-rest context' "$SKILL" || fail "Azure DevOps profile preflight is not documented"
grep -Fq 'Never run `clickup status`' "$SKILL" || fail "tracker write boundary is not documented"

echo "start-work regression checks passed"
