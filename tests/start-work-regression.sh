#!/bin/bash
# Description: Regression coverage for start-work notes and project repository synchronization boundaries

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

# Project repository sync runs against real temporary repositories; only the notes sync above is mocked.
awk '
  /^```bash$/ { count++; inside = (count == 2); next }
  inside && /^```$/ { exit }
  inside { print }
' "$REPO_ROOT/skills/start-work/SKILL.md" > "$TEST_ROOT/project-sync.sh" || fail "could not extract project sync instructions"
[ -s "$TEST_ROOT/project-sync.sh" ] || fail "project sync code block is missing"

PROJECT_HOME="$TEST_ROOT/project-home"
mkdir -p "$PROJECT_HOME" || fail "could not create project fixture home"
git_fixture() {
  HOME="$PROJECT_HOME" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid git "$@"
}
fixture_commit() {
  printf '%s\n' "$2" > "$1/$2.txt"
  git_fixture -C "$1" add "$2.txt" && git_fixture -C "$1" commit -q -m "$2" || fail "could not create fixture commit"
}
run_project_sync() {
  if (cd "$1" && HOME="$PROJECT_HOME" GIT_CONFIG_NOSYSTEM=1 /bin/bash "$TEST_ROOT/project-sync.sh") > "$TEST_ROOT/output" 2>&1; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}
new_project() {
  rm -rf "$TEST_ROOT/remote.git" "$TEST_ROOT/upstream" "$TEST_ROOT/project"
  git_fixture init -q --bare -b master "$TEST_ROOT/remote.git" || fail "could not create fixture remote"
  git_fixture clone -q "$TEST_ROOT/remote.git" "$TEST_ROOT/upstream" 2>/dev/null || fail "could not clone fixture upstream"
  git_fixture -C "$TEST_ROOT/upstream" checkout -q -b master 2>/dev/null || true
  fixture_commit "$TEST_ROOT/upstream" base
  git_fixture -C "$TEST_ROOT/upstream" push -q origin master 2>/dev/null || fail "could not push fixture base"
  git_fixture --git-dir="$TEST_ROOT/remote.git" symbolic-ref HEAD refs/heads/master
  git_fixture clone -q "$TEST_ROOT/remote.git" "$TEST_ROOT/project" 2>/dev/null || fail "could not clone fixture project"
  fixture_commit "$TEST_ROOT/upstream" newer
  git_fixture -C "$TEST_ROOT/upstream" push -q origin master 2>/dev/null || fail "could not push fixture update"
}

NOT_REPO="$TEST_ROOT/not-a-repo"
mkdir -p "$NOT_REPO"
run_project_sync "$NOT_REPO"
[ "$RUN_STATUS" -eq 0 ] || fail "non-repository directory did not stop cleanly"
grep -Fxq 'no project repository' "$TEST_ROOT/output" || fail "non-repository directory was not reported"

new_project
run_project_sync "$TEST_ROOT/project"
[ "$RUN_STATUS" -eq 0 ] || fail "clean default branch sync failed"
grep -Fxq 'fast-forwarded' "$TEST_ROOT/output" || fail "clean default branch was not fast-forwarded"
grep -Fq 'newer' "$TEST_ROOT/output" || fail "fast-forwarded commits were not summarized"
grep -Fq 'ahead 0, behind 0 relative to origin/master' "$TEST_ROOT/output" || fail "synchronized branch did not report zero distance"
[ -f "$TEST_ROOT/project/newer.txt" ] || fail "fast-forward did not update the working tree"

new_project
printf 'local\n' > "$TEST_ROOT/project/base.txt"
run_project_sync "$TEST_ROOT/project"
[ "$RUN_STATUS" -eq 0 ] || fail "dirty default branch sync failed"
if grep -Fq 'fast-forwarded' "$TEST_ROOT/output"; then fail "dirty default branch was updated"; fi
grep -Fq 'uncommitted entries 1' "$TEST_ROOT/output" || fail "dirty default branch did not report uncommitted entries"
grep -Fq 'behind 1 relative to origin/master' "$TEST_ROOT/output" || fail "dirty default branch did not report how far it is behind"
[ ! -f "$TEST_ROOT/project/newer.txt" ] || fail "dirty default branch working tree changed"
[ "$(cat "$TEST_ROOT/project/base.txt")" = local ] || fail "dirty default branch lost its local change"

new_project
fixture_commit "$TEST_ROOT/project" localonly
run_project_sync "$TEST_ROOT/project"
[ "$RUN_STATUS" -eq 0 ] || fail "diverged default branch sync failed"
grep -Fxq 'fast-forward failed' "$TEST_ROOT/output" || fail "diverged default branch did not report the failed fast-forward"
grep -Fq 'ahead 1, behind 1 relative to origin/master' "$TEST_ROOT/output" || fail "diverged default branch did not report both counts"
[ ! -f "$TEST_ROOT/project/newer.txt" ] || fail "diverged default branch was changed"

new_project
git_fixture -C "$TEST_ROOT/project" switch -q -c feature/work
BRANCH_HEAD="$(git_fixture -C "$TEST_ROOT/project" rev-parse HEAD)"
MASTER_BEFORE="$(git_fixture -C "$TEST_ROOT/project" rev-parse master)"
run_project_sync "$TEST_ROOT/project"
[ "$RUN_STATUS" -eq 0 ] || fail "feature branch sync failed"
grep -Fq 'branch feature/work' "$TEST_ROOT/output" || fail "feature branch was not reported"
grep -Fq 'behind 1 relative to origin/master' "$TEST_ROOT/output" || fail "feature branch did not report how far it is behind"
[ "$(git_fixture -C "$TEST_ROOT/project" rev-parse HEAD)" = "$BRANCH_HEAD" ] || fail "feature branch moved"
[ "$(git_fixture -C "$TEST_ROOT/project" branch --show-current)" = feature/work ] || fail "feature branch was switched"
[ "$(git_fixture -C "$TEST_ROOT/project" rev-parse master)" = "$MASTER_BEFORE" ] || fail "feature branch sync moved the local default branch"

new_project
git_fixture -C "$TEST_ROOT/project" remote set-url origin "$TEST_ROOT/missing.git"
run_project_sync "$TEST_ROOT/project"
[ "$RUN_STATUS" -eq 0 ] || fail "fetch failure stopped the sync"
grep -Fq 'fetch failed; counts use the last fetched ref' "$TEST_ROOT/output" || fail "fetch failure was not reported"
if grep -Fq 'fast-forwarded' "$TEST_ROOT/output"; then fail "branch was fast-forwarded after a failed fetch"; fi
if grep -Fq "$TEST_ROOT/missing.git" "$TEST_ROOT/output"; then fail "fetch failure printed the remote URL"; fi

new_project
git_fixture -C "$TEST_ROOT/project" remote set-head origin -d >/dev/null 2>&1 || fail "could not remove the remote default branch"
run_project_sync "$TEST_ROOT/project"
[ "$RUN_STATUS" -eq 0 ] || fail "unknown default branch stopped the sync"
grep -Fxq 'default branch unknown' "$TEST_ROOT/output" || fail "unknown default branch was not reported"

new_project
git_fixture -C "$TEST_ROOT/project" remote rename origin mirror >/dev/null 2>&1 || fail "could not rename the fixture remote"
git_fixture -C "$TEST_ROOT/project" config azure-devops.remote mirror
run_project_sync "$TEST_ROOT/project"
grep -Fxq 'fast-forwarded' "$TEST_ROOT/output" || fail "azure-devops.remote was not used for the sync"
grep -Fq 'relative to mirror/master' "$TEST_ROOT/output" || fail "configured remote was not reported"

SKILL="$REPO_ROOT/skills/start-work/SKILL.md"
grep -Fq 'snapshot --since <date>' "$SKILL" || fail "ClickUp snapshot does not specify a date"
grep -Fq 'date seven days ago' "$SKILL" || fail "ClickUp fallback window is not documented"
grep -Fq 'ado-tasks` from inside the project repository' "$SKILL" || fail "Azure DevOps repository context is not documented"
grep -Fq 'ado-rest context' "$SKILL" || fail "Azure DevOps profile preflight is not documented"
grep -Fq 'Never run `clickup status`' "$SKILL" || fail "tracker write boundary is not documented"
grep -Fq 'Do not pull, rebase, merge, switch branches, stash, or touch other branches' "$SKILL" || fail "project sync write boundary is not documented"

for skill_name in start-work end-work; do
  QA_SKILL="$REPO_ROOT/skills/$skill_name/SKILL.md"
  grep -Fq 'Check QA hand-offs (read-only)' "$QA_SKILL" || fail "$skill_name has no QA hand-off step"
  grep -Fq 'only when the project guide defines a QA hand-off rule' "$QA_SKILL" || fail "$skill_name QA step is not driven by the project guide"
  grep -Fq 'skip the step silently' "$QA_SKILL" || fail "$skill_name does not skip the QA step silently without a rule"
  grep -Fq 'on every run of this skill' "$QA_SKILL" || fail "$skill_name does not say when the QA step runs"
  grep -Fq 'never reassign an item, change a state, or comment' "$QA_SKILL" || fail "$skill_name QA step does not forbid tracker writes"
  grep -Fq 'Do not build the query yourself' "$QA_SKILL" || fail "$skill_name keeps the QA query out of the project guide"
  # Tracker states and people belong to the project guide, not this public skill.
  if grep -Fq 'QA Pending' "$QA_SKILL"; then
    fail "$skill_name names a project-specific tracker state"
  fi
done

grep -Fq 'work in a separate git worktree on a new branch from `origin/main`' "$REPO_ROOT/skills/end-work/SKILL.md" || fail "end-work does not cover a shared notes checkout on a merged branch"

CREATE_PR_SKILL="$REPO_ROOT/skills/create-pr/SKILL.md"
grep -Fq '**Public text check.**' "$CREATE_PR_SKILL" || fail "create-pr has no public text check"
grep -Fq 'skip this check silently' "$CREATE_PR_SKILL" || fail "create-pr public text check is not skipped without a guide list"
grep -Fq 'quote the term only in the conversation' "$CREATE_PR_SKILL" || fail "create-pr may repeat a matched term in public text"

MERGE_PR_SKILL="$REPO_ROOT/skills/merge-pr/SKILL.md"
grep -Fq '**Branch checked out in the main checkout**' "$MERGE_PR_SKILL" || fail "merge-pr has no checked-out branch cleanup"
grep -Fq 'equals the merged PR head' "$MERGE_PR_SKILL" || fail "merge-pr branch cleanup does not require the merged head"
grep -Fq 'change nothing and report why' "$MERGE_PR_SKILL" || fail "merge-pr branch cleanup has no safe fallback"
grep -Fq 'Never apply this to a branch checked out in another worktree' "$MERGE_PR_SKILL" || fail "merge-pr cleanup may touch another worktree"

echo "start-work regression checks passed"
