#!/bin/bash
# Description: Regression coverage for sync-branch upstream restoration

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_BRANCH="$REPO_ROOT/scripts/sync-branch"
REAL_GIT="$(command -v git)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sync-branch-regression.XXXXXX")" || exit 1
TEST_SHIM="$TEST_ROOT/shim"
mkdir -p "$TEST_SHIM" || exit 1

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_original_upstream() {
  local remote merge
  remote="$("$REAL_GIT" -C "$REPO" config --local --get-all 'branch.release/1.2.remote' 2>/dev/null || true)"
  merge="$("$REAL_GIT" -C "$REPO" config --local --get-all 'branch.release/1.2.merge' 2>/dev/null || true)"
  [ "$remote" = origin ] || fail "expected original remote origin, got '$remote'"
  [ "$merge" = refs/heads/old-release/1.2 ] || fail "expected original stale merge ref, got '$merge'"
}

assert_branch_merge_config() {
  local branch="$1"
  local expected="$2"
  local merge
  merge="$("$REAL_GIT" -C "$REPO" config --local --get-all "branch.$branch.merge" 2>/dev/null || true)"
  [ "$merge" = "$expected" ] || fail "expected '$branch' merge config '$expected', got '$merge'"
}

setup_repo() {
  local name="$1"
  TEST_CASE_DIR="$TEST_ROOT/$name"
  REPO="$TEST_CASE_DIR/repo"
  mkdir -p "$REPO" || fail "could not create repository for $name"
  "$REAL_GIT" init --bare -q "$TEST_CASE_DIR/origin.git" || fail "could not initialize origin for $name"
  "$REAL_GIT" init -q "$REPO" || fail "could not initialize repository for $name"
  "$REAL_GIT" -C "$REPO" config user.name "Regression Test" || fail "could not configure author for $name"
  "$REAL_GIT" -C "$REPO" config user.email regression@example.invalid || fail "could not configure email for $name"
  "$REAL_GIT" -C "$REPO" checkout -q -b main || fail "could not create main for $name"
  printf 'base\n' > "$REPO/base.txt"
  "$REAL_GIT" -C "$REPO" add base.txt || fail "could not stage base commit for $name"
  "$REAL_GIT" -C "$REPO" commit -qm "base commit" || fail "could not commit base for $name"
  "$REAL_GIT" -C "$REPO" remote add origin "$TEST_CASE_DIR/origin.git" || fail "could not add origin for $name"
  "$REAL_GIT" -C "$REPO" push -qu origin main || fail "could not push main for $name"
  "$REAL_GIT" -C "$REPO" branch 'release/1.2' || fail "could not create dotted branch for $name"
  "$REAL_GIT" -C "$REPO" config --local 'branch.release/1.2.remote' origin || fail "could not configure stale remote for $name"
  "$REAL_GIT" -C "$REPO" config --local 'branch.release/1.2.merge' refs/heads/old-release/1.2 || fail "could not configure stale merge ref for $name"
}

cat > "$TEST_SHIM/git" <<'EOF'
#!/bin/bash

if [ "${1-}" = branch ] && [ "${2-}" = -d ] && \
  [ -n "${SYNC_TEST_FAIL_BRANCH:-}" ] && [ "${4-}" = "$SYNC_TEST_FAIL_BRANCH" ]; then
  exit 1
fi

case "${2-}" in
  --set-upstream-to=*)
    "$SYNC_BRANCH_REAL_GIT" "$@"
    status=$?
    if [ "$status" -eq 0 ] && [ -n "${SYNC_TEST_SIGNAL:-}" ]; then
      kill -s "$SYNC_TEST_SIGNAL" "$PPID"
    fi
    exit "$status"
    ;;
esac

exec "$SYNC_BRANCH_REAL_GIT" "$@"
EOF
chmod +x "$TEST_SHIM/git" || fail "could not make git shim executable"

run_sync_branch() {
  (
    cd "$REPO" || exit 1
    PATH="$TEST_SHIM:$PATH" \
      SYNC_BRANCH_REAL_GIT="$REAL_GIT" \
      SYNC_TEST_FAIL_BRANCH="${SYNC_TEST_FAIL_BRANCH:-}" \
      SYNC_TEST_SIGNAL="${SYNC_TEST_SIGNAL:-}" \
      "$SYNC_BRANCH" "$@"
  )
}

setup_repo stale-dotted-branch
run_sync_branch --dry-run > "$TEST_CASE_DIR/output" 2>&1 || fail "dry run failed for release/1.2"
grep -Fq 'release/1.2' "$TEST_CASE_DIR/output" || fail "dry run did not report release/1.2 as stale"
grep -Fq 'would delete' "$TEST_CASE_DIR/output" || fail "dry run did not identify release/1.2 as deletable"
"$REAL_GIT" -C "$REPO" show-ref --verify --quiet refs/heads/release/1.2 || fail "dry run removed release/1.2"

setup_repo deletion-failure
SYNC_TEST_FAIL_BRANCH='release/1.2' run_sync_branch > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 1 ] || fail "expected deletion failure status 1, got $status"
"$REAL_GIT" -C "$REPO" show-ref --verify --quiet refs/heads/release/1.2 || fail "failed deletion removed release/1.2"
assert_original_upstream

setup_repo multiple-transactions
"$REAL_GIT" -C "$REPO" branch 'release/2.0' || fail "could not create second dotted branch"
"$REAL_GIT" -C "$REPO" config --local 'branch.release/2.0.remote' origin || fail "could not configure second stale remote"
"$REAL_GIT" -C "$REPO" config --local 'branch.release/2.0.merge' refs/heads/old-release/2.0 || fail "could not configure second stale merge ref"
SYNC_TEST_FAIL_BRANCH='release/1.2' run_sync_branch > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 1 ] || fail "expected one deletion failure across multiple branches, got status $status"
"$REAL_GIT" -C "$REPO" show-ref --verify --quiet refs/heads/release/1.2 || fail "failed first deletion removed release/1.2"
assert_original_upstream
if "$REAL_GIT" -C "$REPO" show-ref --verify --quiet refs/heads/release/2.0; then
  fail "successful second deletion left release/2.0 present"
fi
second_merge_values="$("$REAL_GIT" -C "$REPO" config --local --get-all 'branch.release/2.0.merge' 2>/dev/null || true)"
case $'\n'"$second_merge_values"$'\n' in
  *$'\nrefs/heads/old-release/2.0\n'*) fail "cleanup restored config for a successfully deleted second branch" ;;
esac

for signal in INT TERM; do
  setup_repo "signal-$signal"
  SYNC_TEST_SIGNAL="$signal" run_sync_branch > "$TEST_CASE_DIR/output" 2>&1
  status=$?
  if [ "$signal" = INT ]; then
    expected_status=130
  else
    expected_status=143
  fi
  [ "$status" -eq "$expected_status" ] || fail "expected $signal exit status $expected_status, got $status"
  "$REAL_GIT" -C "$REPO" show-ref --verify --quiet refs/heads/release/1.2 || fail "$signal removed release/1.2"
  assert_original_upstream
done

setup_repo branch-safety
"$REAL_GIT" -C "$REPO" checkout -q -b 'feature/unmerged' || fail "could not create unmerged branch"
printf 'unmerged\n' > "$REPO/unmerged.txt"
"$REAL_GIT" -C "$REPO" add unmerged.txt || fail "could not stage unmerged commit"
"$REAL_GIT" -C "$REPO" commit -qm "unmerged commit" || fail "could not commit unmerged change"
"$REAL_GIT" -C "$REPO" checkout -q main || fail "could not return to main"
"$REAL_GIT" -C "$REPO" config --local 'branch.feature/unmerged.remote' origin || fail "could not configure unmerged remote"
"$REAL_GIT" -C "$REPO" config --local 'branch.feature/unmerged.merge' refs/heads/old-feature/unmerged || fail "could not configure unmerged merge ref"
run_sync_branch > "$TEST_CASE_DIR/output" 2>&1 || fail "normal unmerged-branch run failed"
grep -Fq 'contains commits not confirmed' "$TEST_CASE_DIR/output" || fail "normal run did not skip unmerged branch"
"$REAL_GIT" -C "$REPO" show-ref --verify --quiet refs/heads/feature/unmerged || fail "normal run removed unmerged branch"
run_sync_branch --force --dry-run > "$TEST_CASE_DIR/output" 2>&1 || fail "force dry run failed"
grep -Fq 'would force-delete' "$TEST_CASE_DIR/output" || fail "force dry run did not report force deletion"
"$REAL_GIT" -C "$REPO" show-ref --verify --quiet refs/heads/feature/unmerged || fail "force dry run removed unmerged branch"
run_sync_branch --force > "$TEST_CASE_DIR/output" 2>&1 || fail "force deletion run failed"
if "$REAL_GIT" -C "$REPO" show-ref --verify --quiet refs/heads/feature/unmerged; then
  fail "force deletion left unmerged branch present"
fi

setup_repo checked-out-worktree
"$REAL_GIT" -C "$REPO" worktree add -q "$TEST_CASE_DIR/worktree" 'release/1.2' || fail "could not check out stale branch in worktree"
run_sync_branch --force > "$TEST_CASE_DIR/output" 2>&1 || fail "worktree protection run failed"
grep -Fq 'checked out in' "$TEST_CASE_DIR/output" || fail "run did not report the checked-out worktree"
"$REAL_GIT" -C "$REPO" show-ref --verify --quiet refs/heads/release/1.2 || fail "force run removed branch checked out in another worktree"

setup_repo successful-deletion
run_sync_branch > "$TEST_CASE_DIR/output" 2>&1 || fail "successful deletion run failed"
if "$REAL_GIT" -C "$REPO" show-ref --verify --quiet refs/heads/release/1.2; then
  fail "successful deletion left release/1.2 present"
fi
remaining_merge_values="$("$REAL_GIT" -C "$REPO" config --local --get-all 'branch.release/1.2.merge' 2>/dev/null || true)"
case $'\n'"$remaining_merge_values"$'\n' in
  *$'\nrefs/heads/old-release/1.2\n'*) fail "successful deletion restored the deleted branch's original config" ;;
esac

echo "sync-branch regression checks passed"
