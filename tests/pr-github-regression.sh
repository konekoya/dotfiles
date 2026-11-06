#!/bin/bash
# Description: Mock-only regression coverage for GitHub pr list and status
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pr-github.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/dotfiles/scripts" "$TEST_ROOT/dotfiles/lib" "$TEST_ROOT/bin" "$TEST_ROOT/repo"
export HOME="$TEST_ROOT/home" XDG_CONFIG_HOME="$TEST_ROOT/home/.config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG GIT_CONFIG_COUNT GH_TOKEN GITHUB_TOKEN
unset AZURE_DEVOPS_ORG AZURE_DEVOPS_PROFILE AZURE_DEVOPS_PAT
cp "$REPO_ROOT/scripts/pr" "$TEST_ROOT/dotfiles/scripts/"
cp "$REPO_ROOT"/lib/*.sh "$TEST_ROOT/dotfiles/lib/"
# Fail if the GitHub path tries to load Azure credentials or bind a profile.
cat >> "$TEST_ROOT/dotfiles/lib/azure-devops.sh" <<'EOF_GUARD'
ado_resolve_repo_context() { echo forbidden-azure >&2; exit 90; }
ado_bind_profile() { echo forbidden-azure >&2; exit 90; }
ado_get_auth_header() { echo forbidden-azure >&2; exit 90; }
EOF_GUARD
cat > "$TEST_ROOT/dotfiles/lib/local-env.sh" <<'EOF_GUARD'
echo forbidden-local-env >&2
exit 90
EOF_GUARD
export FIXTURE_ROOT="$TEST_ROOT"
cat > "$TEST_ROOT/bin/gh-auth" <<'EOF_MOCK'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$FIXTURE_ROOT/calls"
case "$*" in *'--repo example/sample'*) ;; *) exit 80 ;; esac
case "${MODE:-}" in
  transport|auth) echo synthetic-sensitive-diagnostic >&2; echo synthetic-sensitive-body; exit 1 ;;
  invalid) echo synthetic-sensitive-body; exit 0 ;;
  multiple) cat "$FIXTURE_ROOT/view"; cat "$FIXTURE_ROOT/view"; exit 0 ;;
esac
[ "$1" = pr ] || exit 81
case "$2" in
  view)
    n=0
    [ ! -f "$FIXTURE_ROOT/count" ] || n=$(cat "$FIXTURE_ROOT/count")
    n=$((n + 1)); echo "$n" > "$FIXTURE_ROOT/count"
    if [ "${MODE:-}" = watch ] && [ "$n" -gt 1 ]; then cat "$FIXTURE_ROOT/view-next"; else cat "$FIXTURE_ROOT/view"; fi ;;
  list)
    case "$*" in
      *'--head '*) cat "$FIXTURE_ROOT/branch" ;;
      *'--author @me'*) cat "$FIXTURE_ROOT/authored" ;;
      *'--search review-requested:@me'*) cat "$FIXTURE_ROOT/reviews" ;;
      *) exit 82 ;;
    esac ;;
  *) exit 83 ;;
esac
EOF_MOCK
cat > "$TEST_ROOT/bin/sleep" <<'EOF_MOCK'
#!/bin/bash
[ "$1" = 1 ] || exit 84
EOF_MOCK
chmod +x "$TEST_ROOT/bin/gh-auth" "$TEST_ROOT/bin/sleep"
export PATH="$TEST_ROOT/bin:$PATH"
cd "$TEST_ROOT/repo"
git init -q
git -c user.name=Fixture -c user.email=fixture@example.invalid -c core.hooksPath=/dev/null commit --allow-empty -qm fixture
git branch -m feature/test
git remote add origin git@github.com:example/sample.git
# An invalid Azure profile and override must be irrelevant on GitHub.
git config azure-devops.profile missing
export AZURE_DEVOPS_ORG=wrong-org
PR="$TEST_ROOT/dotfiles/scripts/pr"
view() {
  jq -cn --argjson checks "$1" '{number:42,title:"Fixture",state:"OPEN",headRefOid:("a" * 40),reviewDecision:"REVIEW_REQUIRED",statusCheckRollup:$checks}' > "$TEST_ROOT/view"
}
run() {
  : > "$TEST_ROOT/calls"
  rc=0
  "$PR" "$@" > "$TEST_ROOT/out" 2> "$TEST_ROOT/err" || rc=$?
  if grep -Eq 'synthetic-sensitive|forbidden-|https?://' "$TEST_ROOT/out" "$TEST_ROOT/err"; then fail 'sensitive/raw output'; fi
}
ok() { [ "$rc" -eq 0 ] || fail "$* (exit $rc)"; }
bad() { [ "$rc" -ne 0 ] || fail "$* accepted"; }
state() { jq -e --arg state "$1" '.state == $state' "$TEST_ROOT/out" >/dev/null || fail "expected $1"; }
view '[]'
printf '%s\n' '[{"number":42,"headRefName":"feature/test","headRepository":{"name":"sample"},"headRepositoryOwner":{"login":"example"},"isCrossRepository":false}]' > "$TEST_ROOT/branch"
printf '%s\n' '[{"number":42,"title":"Authored","author":{"login":"me"},"headRefName":"feature/test","baseRefName":"main"}]' > "$TEST_ROOT/authored"
printf '%s\n' '[{"number":43,"title":"Review","author":{"login":"other"},"headRefName":"other","baseRefName":"main"}]' > "$TEST_ROOT/reviews"
run list; ok list
grep -q 'Created by me (1)' "$TEST_ROOT/out" || fail authored
grep -q 'Awaiting my review (1)' "$TEST_ROOT/out" || fail reviewer
printf '[]' > "$TEST_ROOT/authored"; printf '[]' > "$TEST_ROOT/reviews"
run list; ok empty-list
grep -q '(none)' "$TEST_ROOT/out" || fail empty-list
for remote in 'https://github.com/example/sample.git' 'ssh://git@github.com/example/sample.git' 'git@github.com:example/sample.git'; do
  git remote set-url origin "$remote"
  run status 42 --json; ok remote; state none
done
git remote add selected https://github.com/example/sample.git
git config azure-devops.remote selected
git remote set-url origin https://github.com/wrong/repo.git
run status --json; ok selected-branch; state none
grep -q -- '--head feature/test' "$TEST_ROOT/calls" || fail branch-query
git remote set-url --push selected https://github.com/example/other.git
run status 42 --json; bad mismatch
[ ! -s "$TEST_ROOT/calls" ] || fail mismatch-api
git remote set-url --push selected https://github.com/example/sample.git
for checks in '[]' null; do
  view "$checks"; run status 42 --json; ok no-checks; state none
done
jq 'del(.statusCheckRollup)' "$TEST_ROOT/view" > "$TEST_ROOT/new"; mv "$TEST_ROOT/new" "$TEST_ROOT/view"
run status 42 --json; bad missing-rollup
for checks in '"bad"' '[null]'; do view "$checks"; run status 42 --json; bad malformed-checks; done
for pair in 'SUCCESS succeeded' 'NEUTRAL succeeded' 'SKIPPED succeeded' 'FAILURE failed' 'CANCELLED failed' 'TIMED_OUT failed' 'ACTION_REQUIRED failed' 'STARTUP_FAILURE failed' 'FUTURE pending'; do
  read -r conclusion expected <<< "$pair"
  view "[{\"__typename\":\"CheckRun\",\"status\":\"COMPLETED\",\"conclusion\":\"$conclusion\"}]"
  run status 42 --json; ok checkrun; state "$expected"
done
for status in QUEUED IN_PROGRESS WAITING REQUESTED PENDING FUTURE; do
  view "[{\"__typename\":\"CheckRun\",\"status\":\"$status\",\"conclusion\":\"SUCCESS\"}]"
  run status 42 --json; ok running; state pending
done
for pair in 'SUCCESS succeeded' 'ERROR failed' 'FAILURE failed' 'PENDING pending' 'EXPECTED pending' 'FUTURE pending'; do
  read -r context expected <<< "$pair"
  view "[{\"__typename\":\"StatusContext\",\"state\":\"$context\"}]"
  run status 42 --json; ok context; state "$expected"
done
for checks in '[{}]' '[{"__typename":"Future","state":"SUCCESS"}]' '[{"__typename":"CheckRun","status":"COMPLETED"}]'; do
  view "$checks"; run status 42 --json; ok unknown; state pending
  jq -e '.checks[0].state == "unknown"' "$TEST_ROOT/out" >/dev/null || fail unknown
done
view '[{"__typename":"StatusContext","state":"SUCCESS","url":"https://synthetic-sensitive.invalid","extra":"synthetic-sensitive"}]'
run status 42 --json; ok allowlist
jq -e '. == {pullRequestId:42,organization:"example",project:null,repository:"sample",state:"succeeded",checks:[{state:"succeeded",buildId:null}]}' "$TEST_ROOT/out" >/dev/null || fail allowlist
for branch_mode in zero ambiguous other-branch fork malformed; do
  cp "$TEST_ROOT/branch" "$TEST_ROOT/saved"
  case "$branch_mode" in
    zero) echo '[]' > "$TEST_ROOT/branch" ;;
    ambiguous) jq '. + .' "$TEST_ROOT/saved" > "$TEST_ROOT/branch" ;;
    other-branch) jq '.[0].headRefName = "feature/other"' "$TEST_ROOT/saved" > "$TEST_ROOT/branch" ;;
    fork) jq '.[0].headRepositoryOwner.login = "fork" | .[0].isCrossRepository = true' "$TEST_ROOT/saved" > "$TEST_ROOT/branch" ;;
    malformed) echo '{}' > "$TEST_ROOT/branch" ;;
  esac
  run status --json; bad "$branch_mode"
  mv "$TEST_ROOT/saved" "$TEST_ROOT/branch"
done
git checkout --detach -q
run status --json; bad detached
[ ! -s "$TEST_ROOT/calls" ] || fail detached-api
git checkout -q feature/test
for args in 'status 0' 'status 42 43' 'status --interval' 'status --interval 0' 'status --interval -1' 'status --interval x' 'status --bad' 'status --json --watch' 'list --json'; do
  # shellcheck disable=SC2086 # Deliberate argument vectors with no quoting needs.
  run $args; [ "$rc" -eq 2 ] || fail "invalid args: $args"
  [ ! -s "$TEST_ROOT/calls" ] || fail invalid-api
done
for mode in auth transport invalid multiple; do
  export MODE="$mode"
  run status 42 --json; bad "$mode"
  run list; bad "list-$mode"
done
unset MODE
for command in list status; do
  if [ "$command" = list ]; then file=authored; else file=view; fi
  cp "$TEST_ROOT/$file" "$TEST_ROOT/saved"
  echo '{}' > "$TEST_ROOT/$file"
  run "$command"; bad malformed
  mv "$TEST_ROOT/saved" "$TEST_ROOT/$file"
done
jq -cn '[range(1000) | {number:42,title:"Cap",author:{login:"me"},headRefName:"feature",baseRefName:"main"}]' > "$TEST_ROOT/authored"
run list; bad cap
view '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]'
jq '.headRefOid = ("b" * 40)' "$TEST_ROOT/view" > "$TEST_ROOT/view-next"
for checks in '[]' null '[{"__typename":"StatusContext","state":"PENDING"}]'; do
  view "$checks"; rm -f "$TEST_ROOT/count"
  export MODE=watch
  run status 42 --watch --interval 1; ok watch
  [ "$(cat "$TEST_ROOT/count")" -eq 2 ] || fail watch-refresh
  grep -q 'Head: aaaaaaaaaa' "$TEST_ROOT/out" || fail first-head
  grep -q 'Head: bbbbbbbbbb' "$TEST_ROOT/out" || fail second-head
  unset MODE
done
view '[{"__typename":"StatusContext","state":"FAILURE"}]'
rm -f "$TEST_ROOT/count"
run status 42 --watch; ok failed-watch-exit
[ "$(cat "$TEST_ROOT/count")" -eq 1 ] || fail failed-watch-poll
# Exercise the real timeout loop without a nine-minute wall-clock wait.
# Advance Bash SECONDS only after the real snapshot completes; production has no test hook.
view null
rc=0
/bin/bash -c '
  set -euo pipefail
  source "$1/lib/pr-github.sh"
  GITHUB_OWNER=example GITHUB_REPO=sample
  eval "$(declare -f pr_github_snapshot | sed "1s/pr_github_snapshot/pr_github_real_snapshot/")"
  pr_github_snapshot() { pr_github_real_snapshot; SECONDS=$((SECONDS + 541)); }
  pr_github_status 42 --watch --interval 1
' fixture "$TEST_ROOT/dotfiles" > "$TEST_ROOT/out" 2> "$TEST_ROOT/err" || rc=$?
ok timeout-exit
grep -q 'Still pending after ~9 minutes' "$TEST_ROOT/out" || fail timeout-message
run comments 42; bad comments
[ ! -s "$TEST_ROOT/calls" ] || fail comments-api
run merge 42; bad merge
[ ! -s "$TEST_ROOT/calls" ] || fail merge-api
echo 'GitHub PR regression checks passed'
