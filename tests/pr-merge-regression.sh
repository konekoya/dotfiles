#!/bin/bash
# Description: Regression coverage for pr merge (preview, --execute and --requeue-expired) against a mocked Azure DevOps API

# Every request is answered by a curl shim from fixture files; nothing here contacts a real
# organization, and every token and identifier is synthetic.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REAL_GIT="$(command -v git)" || exit 1
REAL_GREP="$(command -v grep)" || exit 1
REAL_BASE64="$(command -v base64)" || exit 1
REAL_TR="$(command -v tr)" || exit 1
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pr-merge-regression.XXXXXX")" || exit 1
BASE_BIN="$TEST_ROOT/base-bin"
MOCK_BIN="$TEST_ROOT/mock-bin"
MOCK_DIR="$TEST_ROOT/mock"
BASE_DIR="$TEST_ROOT/base"
ERR_FILE="$TEST_ROOT/stderr"
mkdir -p "$BASE_BIN" "$MOCK_BIN" "$MOCK_DIR" "$BASE_DIR" || exit 1

unset AZURE_DEVOPS_ORG AZURE_DEVOPS_PROFILE AZURE_DEVOPS_PAT AZURE_DEVOPS_PAT_WORK AZURE_DEVOPS_PAT_PERSONAL
ISOLATED_HOME="$TEST_ROOT/home"
mkdir -p "$ISOLATED_HOME/.config" || exit 1
: > "$TEST_ROOT/empty-gitconfig"
export HOME="$ISOLATED_HOME" XDG_CONFIG_HOME="$ISOLATED_HOME/.config"
export GIT_CONFIG_GLOBAL="$TEST_ROOT/empty-gitconfig" GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG GIT_CONFIG_COUNT

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The script under test runs with a PATH of mock curl plus these tools only.
for tool in git jq base64 tr head tail sed grep dirname basename readlink cat sleep cmp rm mkdir date awk sort uniq wc mktemp env ls cp mv ln stat chmod id uname; do
  if tool_path="$(command -v "$tool")"; then
    ln -s "$tool_path" "$BASE_BIN/$tool" || fail "could not link $tool"
  fi
done

# Scripts locate lib/ and alias/.env from their own path; a fixture copy never sees a real alias/.env.
FIXTURE_DOTFILES="$TEST_ROOT/dotfiles"
mkdir -p "$FIXTURE_DOTFILES/scripts" "$FIXTURE_DOTFILES/lib" "$FIXTURE_DOTFILES/alias" || exit 1
cp "$REPO_ROOT"/lib/*.sh "$FIXTURE_DOTFILES/lib/" || exit 1
cp "$REPO_ROOT/scripts/pr" "$FIXTURE_DOTFILES/scripts/pr" || exit 1
PR="$FIXTURE_DOTFILES/scripts/pr"

# ── Mock curl: logs every request and answers from fixture files ─────
cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_DIR/argv.log"
auth_header=""
url=""
method=GET
body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H)
      shift
      case "${1-}" in
        @*)
          auth_path="${1#@}"
          [ -p "$auth_path" ] || exit 10
          auth_header="$(cat "$auth_path")"
          ;;
      esac
      ;;
    -X) shift; method="$1" ;;
    -d) shift; body="$1" ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
printf '%s %s\n' "$method" "$url" >> "$MOCK_DIR/requests.log"
printf '%s\n' "$auth_header" >> "$MOCK_DIR/header.log"

code=200
case "$method $url" in
  "GET "*"/_apis/policy/evaluations?"*) out="$(cat "$MOCK_DIR/evals.json")" ;;
  "GET "*"/_apis/build/builds?"*) out="$(cat "$MOCK_DIR/builds.json")" ;;
  "GET "*"/pullrequests?searchCriteria"*) out='{"value":[{"pullRequestId":123}]}' ;;
  "GET "*"/pullrequests/"[0-9]*)
    n=$(( $(cat "$MOCK_DIR/pr.count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$MOCK_DIR/pr.count"
    if [ -f "$MOCK_DIR/pr.fail" ]; then
      code="$(cat "$MOCK_DIR/pr.fail")"
      out='{"message":"error-body-secret"}'
    elif [ -f "$MOCK_DIR/pr.$n.json" ]; then
      out="$(cat "$MOCK_DIR/pr.$n.json")"
    else
      out="$(cat "$MOCK_DIR/pr.json")"
    fi
    ;;
  "PATCH "*"/_apis/policy/evaluations/"*)
    printf '%s\n' "$url" >> "$MOCK_DIR/requeue.log"
    printf '%s\n' "$body" >> "$MOCK_DIR/requeue.body"
    out='{}'
    ;;
  "PATCH "*"/pullrequests/"*)
    printf '%s' "$body" > "$MOCK_DIR/patch.body"
    code="$(cat "$MOCK_DIR/patch.http" 2>/dev/null || echo 200)"
    out='{"status":"active"}'
    ;;
  *)
    printf '%s %s\n' "$method" "$url" >> "$MOCK_DIR/unexpected.log"
    code=404
    out='{}'
    ;;
esac
printf '%s\n' "$out"
printf '\n%s\n' "$code"
EOF
chmod +x "$MOCK_BIN/curl" || fail "could not make the curl mock executable"

# ── Fixtures ─────────────────────────────────────────────────────────
HEAD_SHA="$(printf '%040d' 0 | tr 0 a)"
MERGE_SHA="$(printf '%040d' 0 | tr 0 b)"
OTHER_SHA="$(printf '%040d' 0 | tr 0 c)"
DONE_SHA="$(printf '%040d' 0 | tr 0 d)"
HEAD8="${HEAD_SHA:0:8}"
PROJECT_ID="11111111-1111-4111-8111-111111111111"
EVAL_BUILD="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1"
EVAL_REVIEW="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2"
API_BASE='https://dev.azure.com/merge-org/merge-project'
PR_URL="$API_BASE/_apis/git/repositories/merge-repo/pullrequests/123?api-version=7.1"
EVALS_URL="$API_BASE/_apis/policy/evaluations?artifactId=vstfs%3A%2F%2F%2FCodeReview%2FCodeReviewId%2F${PROJECT_ID}%2F123&api-version=7.1-preview.1"
BUILDS_URL="$API_BASE/_apis/build/builds?branchName=refs/pull/123/merge&\$top=100&queryOrder=queueTimeDescending&api-version=7.1"
AZURE_DEVOPS_PAT_WORK="synthetic-merge-pat"
export AZURE_DEVOPS_PAT_WORK

DESCRIPTION=$'Body line\n\n<!-- risk-assessment:start -->\n**Overall risk: 🟡 Medium (2/3)**: focused review · scored at `aaaaaaa`\n#### Security\n- [x] Check A\n<!-- risk-assessment:end -->\n\nTrailer text'

jq -n --arg d "$DESCRIPTION" --arg h "$HEAD_SHA" --arg m "$MERGE_SHA" --arg pid "$PROJECT_ID" '
  {pullRequestId: 123, status: "active", isDraft: false, mergeStatus: "succeeded", title: "Add widget",
   description: $d, lastMergeSourceCommit: {commitId: $h}, lastMergeCommit: {commitId: $m},
   reviewers: [{displayName: "Reviewer", vote: 10, isRequired: true}],
   repository: {id: "repo-id", project: {id: $pid}}}' > "$BASE_DIR/pr.json" || fail "could not write the PR fixture"
jq -n --arg b "$EVAL_BUILD" --arg r "$EVAL_REVIEW" '
  {value: [
    {evaluationId: $b, status: "approved", configuration: {isBlocking: true, isEnabled: true, type: {displayName: "Build"}, settings: {buildDefinitionId: 7}}, context: {buildId: 501, isExpired: false}},
    {evaluationId: $r, status: "approved", configuration: {isBlocking: true, isEnabled: true, type: {displayName: "Minimum number of reviewers"}, settings: {}}}]}' > "$BASE_DIR/evals.json" || fail "could not write the evaluations fixture"
jq -n --arg m "$MERGE_SHA" '
  {value: [{id: 501, status: "completed", result: "succeeded", sourceVersion: $m, definition: {id: 7, name: "CI"}}]}' > "$BASE_DIR/builds.json" || fail "could not write the builds fixture"

fixtures() {
  rm -f "$MOCK_DIR"/*
  cp "$BASE_DIR"/*.json "$MOCK_DIR/"
}

# mutate pr|evals|builds 'jq filter'
mutate() {
  jq -c "$2" "$MOCK_DIR/$1.json" > "$MOCK_DIR/$1.tmp" || fail "bad fixture mutation: $2"
  mv "$MOCK_DIR/$1.tmp" "$MOCK_DIR/$1.json"
}

# A repository whose origin is a canonical Azure DevOps HTTPS remote with a PAT profile.
make_repo() {
  local dir="$TEST_ROOT/$1" remote="$2"
  mkdir -p "$dir" && "$REAL_GIT" -C "$dir" init -q -b main || fail "could not create $1"
  "$REAL_GIT" -C "$dir" remote add origin "$remote" || fail "could not add origin to $1"
  "$REAL_GIT" -C "$dir" -c user.name=Regression -c user.email=regression@example.invalid -c core.hooksPath=/dev/null \
    commit --allow-empty -qm fixture || fail "could not commit in $1"
  printf '%s' "$dir"
}
AZURE_REPO="$(make_repo azure https://dev.azure.com/merge-org/merge-project/_git/merge-repo)"
"$REAL_GIT" -C "$AZURE_REPO" config azure-devops.work.organization merge-org
"$REAL_GIT" -C "$AZURE_REPO" config azure-devops.work.auth pat
"$REAL_GIT" -C "$AZURE_REPO" config azure-devops.profile work
GITHUB_REPO="$(make_repo github git@github.com:example/sample.git)"
MERGE_REPO="$AZURE_REPO"

OUT=""
ERR=""
STATUS=0
run_merge() {
  : > "$MOCK_DIR/requests.log"
  rm -f "$MOCK_DIR/patch.body" "$MOCK_DIR/requeue.log" "$MOCK_DIR/requeue.body" "$MOCK_DIR/pr.count" "$MOCK_DIR/header.log" "$MOCK_DIR/argv.log" "$MOCK_DIR/unexpected.log"
  OUT="$(cd "$MERGE_REPO" && PATH="$MOCK_BIN:$BASE_BIN" MOCK_DIR="$MOCK_DIR" "$PR" merge "$@" 2> "$ERR_FILE")"
  STATUS=$?
  ERR="$(cat "$ERR_FILE")"
}

assert_equal() {
  [ "$2" = "$1" ] || fail "$3: expected '$1', got '$2'"
}
assert_has() {
  case "$1" in *"$2"*) ;; *) fail "$3: output lacks '$2': $1" ;; esac
}
assert_lacks() {
  case "$1" in *"$2"*) fail "$3: output unexpectedly has '$2'" ;; esac
}
assert_no_write() {
  if "$REAL_GREP" -Eq '^(PATCH|POST|PUT|DELETE) ' "$MOCK_DIR/requests.log"; then
    fail "$1: a write request was sent: $(cat "$MOCK_DIR/requests.log")"
  fi
  [ ! -e "$MOCK_DIR/unexpected.log" ] || fail "$1: unexpected request: $(cat "$MOCK_DIR/unexpected.log")"
}
assert_requests() {
  local label="$1" expected="$2"
  assert_equal "$expected" "$(cat "$MOCK_DIR/requests.log")" "$label request sequence"
}
json_field() {
  printf '%s' "$OUT" | jq -r "$1"
}

# ── Usage errors send nothing ────────────────────────────────────────
fixtures
for args in \
  "--execute" \
  "123 --execute" \
  "123 --execute --head abc" \
  "123 --execute --head nothex12" \
  "123 --head $HEAD8" \
  "--requeue-expired" \
  "123 --execute --head $HEAD8 --requeue-expired" \
  "123 --requeue-expired --execute --head $HEAD8" \
  "123 --requeue-expired --json" \
  "123 --requeue-expired --waive-checklist" \
  "abc" \
  "123 456" \
  "123 --bogus" \
  "123 --execute --head $HEAD8 --interval 0" \
  "123 --execute --head $HEAD8 --timeout x"; do
  # shellcheck disable=SC2086 # word splitting of the fixed test arguments is intended
  run_merge $args
  assert_equal 2 "$STATUS" "usage error for '$args'"
  assert_equal "" "$(cat "$MOCK_DIR/requests.log")" "usage error '$args' sent a request"
done
run_merge 123 --execute --head "$HEAD8" --requeue-expired
assert_has "$ERR" "cannot be combined" "execute/requeue rejection message"

run_merge --help
assert_equal 0 "$STATUS" "pr merge --help"
assert_has "$OUT" "--waive-checklist" "pr merge --help text"
assert_has "$OUT" "never bypasses policy" "pr merge --help documents the policy rule"
assert_equal "" "$(cat "$MOCK_DIR/requests.log")" "--help sent a request"
out_pr_help="$(PATH="$MOCK_BIN:$BASE_BIN" "$PR" --help 2>&1)"
assert_has "$out_pr_help" "merge [ID]" "pr --help lists merge"

# ── Preview: GET only, exact request sequence ────────────────────────
fixtures
run_merge 123
assert_equal 0 "$STATUS" "ready preview exit status"
assert_has "$OUT" "Verdict: ready" "ready preview verdict"
assert_has "$OUT" "pr merge 123 --execute --head $HEAD_SHA" "ready preview names the pinned head"
assert_has "$OUT" "Checklist: 1/1 ticked (checklist complete)" "ready preview checklist state"
assert_has "$OUT" "Overall risk: 🟡 Medium (2/3)" "preview prints the rating line"
assert_no_write "preview"
assert_requests "preview" "GET $PR_URL
GET $EVALS_URL
GET $BUILDS_URL"

# Without an ID the preview resolves the active PR of the current branch first.
fixtures
"$REAL_GIT" -C "$AZURE_REPO" checkout -q -b feature/merge-test
run_merge
assert_equal 0 "$STATUS" "preview of the current branch's PR"
assert_has "$(head -n 1 "$MOCK_DIR/requests.log")" "/pullrequests?searchCriteria.sourceRefName=refs/heads/feature%2Fmerge-test&searchCriteria.status=active" "branch lookup"
assert_no_write "preview by branch"
"$REAL_GIT" -C "$AZURE_REPO" checkout -q main

# ── --json shape ─────────────────────────────────────────────────────
fixtures
run_merge 123 --json
assert_equal 0 "$STATUS" "--json preview exit status"
assert_equal '["approvals","builds","checklist","head","isDraft","mergeCommit","mergeStatus","organization","policies","project","pullRequestId","reasons","repository","status","verdict"]' \
  "$(printf '%s' "$OUT" | jq -c 'keys')" "--json top-level keys"
assert_equal '["present","scoredAtCurrent","staleBlocking","ticked","total","unreadable","unticked","untickedBlocking","waivedStale","waivedUnticked"]' \
  "$(printf '%s' "$OUT" | jq -c '.checklist | keys')" "--json checklist keys"
assert_equal '{"pullRequestId":123,"organization":"merge-org","project":"merge-project","repository":"merge-repo","status":"active","isDraft":false,"mergeStatus":"succeeded"}' \
  "$(printf '%s' "$OUT" | jq -c '{pullRequestId, organization, project, repository, status, isDraft, mergeStatus}')" "--json identity fields"
assert_equal ready "$(json_field .verdict)" "--json verdict"
assert_equal "$HEAD_SHA" "$(json_field .head)" "--json head"
assert_equal "$MERGE_SHA" "$(json_field .mergeCommit)" "--json mergeCommit"
assert_equal '[{"definitionId":7,"state":"succeeded","current":true}]' "$(printf '%s' "$OUT" | jq -c .builds)" "--json builds"
assert_equal '[{"kind":"build","status":"approved","blocking":true},{"kind":"minimumReviewers","status":"approved","blocking":true}]' \
  "$(printf '%s' "$OUT" | jq -c .policies)" "--json policies"

# JSON and text output carry no URL, header or credential, and API text is redacted.
fixtures
SECRET_DESC=$'<!-- risk-assessment:start -->\n**Overall risk: x** · scored at `aaaaaaa`\n#### Sec\033]0;evil\007-ity\n- [ ] Click https://tok.invalid/z \033[31mred\033[0m now\n<!-- risk-assessment:end -->'
mutate pr ".description = $(jq -Rn --arg d "$SECRET_DESC" '$d')"
mutate pr '.title = "Add https://title.invalid/t widget"'
mutate builds '.value[0].definition.name = "CI https://user:pw@example.invalid/x"'
mutate evals '.value += [{"evaluationId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee3","status":"rejected","configuration":{"isBlocking":true,"isEnabled":true,"type":{"displayName":"Custom https://secret.invalid/y"},"settings":{}}}]'
run_merge 123 --json
EXPECTED_BASIC="Authorization: Basic $(printf ':%s' "$AZURE_DEVOPS_PAT_WORK" | "$REAL_BASE64" | "$REAL_TR" -d '\r\n')"
for leak in invalid "http" "Authorization" "$AZURE_DEVOPS_PAT_WORK" "${EXPECTED_BASIC#Authorization: Basic }" "https:" "Custom" "CI "; do
  assert_lacks "$OUT$ERR" "$leak" "--json output"
done
run_merge 123
assert_has "$OUT" "[url]" "text output redacts URLs"
assert_has "$OUT" "policy_not_approved: Required policy \"Custom [url]\" is rejected." "policy name is redacted in the reason"
assert_has "$OUT" "☐ [Sec-ity] Click [url] red now" "unticked item is printed cleaned"
assert_has "$OUT" "Add [url] widget" "title is redacted"
for leak in invalid $'\033' $'\a' "http" "Authorization" "$AZURE_DEVOPS_PAT_WORK"; do
  assert_lacks "$OUT$ERR" "$leak" "text output"
done

# ── Every not-ready reason blocks the preview verdict and --execute, with no write ──
check_blocked() { # label fixture-file jq-filter expected-code
  fixtures
  mutate "$2" "$3"
  run_merge 123 --json
  assert_equal 0 "$STATUS" "$1: preview exit status"
  assert_equal blocked "$(json_field .verdict)" "$1: preview verdict"
  printf '%s' "$OUT" | jq -e --arg c "$4" '.reasons | map(.code) | index($c) != null' >/dev/null || fail "$1: reason $4 missing: $OUT"
  assert_no_write "$1 preview"
  run_merge 123 --execute --head "$HEAD8" --interval 1 --timeout 2
  assert_equal 1 "$STATUS" "$1: --execute exit status"
  assert_has "$OUT" "Refusing to merge" "$1: refusal message"
  assert_has "$OUT" "❌ $4:" "$1: refusal names the reason"
  assert_no_write "$1 --execute"
  [ ! -e "$MOCK_DIR/patch.body" ] || fail "$1: a merge body was sent"
}
check_blocked "non-active PR" pr '.status = "completed"' not_active
check_blocked "draft" pr '.isDraft = true' draft
check_blocked "conflict" pr '.mergeStatus = "conflicts" | del(.lastMergeCommit)' conflict
check_blocked "merge status pending" pr '.mergeStatus = "queued"' merge_status
check_blocked "reject vote" pr '.reviewers += [{"displayName":"X","vote":-10}]' approval_rejected
check_blocked "waiting for author" pr '.reviewers += [{"displayName":"X","vote":-5}]' approval_rejected
check_blocked "missing approval" pr '.reviewers = [{"displayName":"R","vote":0}]' approval_missing
check_blocked "required reviewer has not voted" pr '.reviewers += [{"displayName":"Req","vote":0,"isRequired":true}]' approval_missing
check_blocked "reviewer policy not approved" evals '.value[1].status = "rejected"' policy_not_approved
check_blocked "failing build" builds '.value[0].result = "failed"' build_failed
check_blocked "pending build" builds '.value[0].status = "inProgress" | del(.value[0].result)' build_pending
check_blocked "build on an older commit" builds ".value[0].sourceVersion = \"$OTHER_SHA\"" build_stale
check_blocked "no build for the pipeline" builds '.value = []' build_missing
check_blocked "build for another pipeline only" builds '.value[0].definition.id = 99' build_missing
check_blocked "expired build" evals '.value[0].context.isExpired = true' build_expired
check_blocked "unticked checklist item" pr '.description |= sub("\\[x\\]"; "[ ]")' checklist_unticked
check_blocked "stale checklist score" pr '.description |= sub("scored at `aaaaaaa`"; "scored at `ccccccc`")' checklist_stale
check_blocked "unterminated risk block" pr '.description |= sub("<!-- risk-assessment:end -->"; "")' checklist_unreadable
check_blocked "AI co-author trailer" pr '.description += "\n\nCo-Authored-By: Claude <noreply@anthropic.com>"' message_attribution
check_blocked "generated-with line" pr '.description += "\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"' message_attribution

# A stale older-commit build is not "succeeded on the current head" even when its evaluation is green.
fixtures
mutate builds ".value[0].sourceVersion = \"$OTHER_SHA\""
run_merge 123 --json
assert_equal false "$(printf '%s' "$OUT" | jq -r '.builds[0].current')" "stale build is not current"

# ── Unknown or missing API fields fail closed ────────────────────────
check_blocked "unknown evaluation status" evals '.value[0].status = "mystery"' unknown_policy_state
check_blocked "evaluation without isBlocking" evals 'del(.value[0].configuration.isBlocking)' unknown_policy_state
check_blocked "evaluation without a type" evals 'del(.value[1].configuration.type)' unknown_policy_state
check_blocked "evaluations array missing" evals '{message: "oops"}' unknown_policy_state
check_blocked "build evaluation without a definition id" evals 'del(.value[0].configuration.settings.buildDefinitionId)' unknown_policy_state
check_blocked "build without sourceVersion" builds 'del(.value[0].sourceVersion)' unknown_policy_state
check_blocked "completed build without a result" builds 'del(.value[0].result)' unknown_policy_state
check_blocked "build in an unknown state" builds '.value[0].status = "mystery"' unknown_policy_state
check_blocked "unknown merge status" pr '.mergeStatus = "mystery"' unknown_policy_state
check_blocked "missing merge status" pr 'del(.mergeStatus)' unknown_policy_state
check_blocked "missing draft flag" pr 'del(.isDraft)' unknown_policy_state
check_blocked "unknown PR status" pr '.status = "mystery"' unknown_policy_state
check_blocked "out-of-range reviewer vote" pr '.reviewers += [{"displayName":"X","vote":7}]' unknown_policy_state
check_blocked "missing source commit" pr 'del(.lastMergeSourceCommit)' unknown_policy_state
check_blocked "missing merge commit" pr 'del(.lastMergeCommit)' unknown_policy_state
check_blocked "malformed merge commit" pr '.lastMergeCommit.commitId = "xyz"' unknown_policy_state
check_blocked "missing title" pr 'del(.title)' unknown_policy_state
check_blocked "missing project id" pr 'del(.repository.project)' unknown_policy_state
fixtures
mutate evals '.value[0].status = "mystery"'
run_merge 123 --json
assert_equal blocked "$(json_field .verdict)" "unknown status is never ready"
assert_equal '[{"kind":"build","status":"unknown","blocking":true},{"kind":"minimumReviewers","status":"approved","blocking":true}]' \
  "$(printf '%s' "$OUT" | jq -c .policies)" "unknown status is reported as unknown"

# Checklist states that do not block.
fixtures
mutate pr '.description = "Plain description"'
run_merge 123
assert_has "$OUT" "Checklist: no risk assessment" "no risk block"
assert_has "$OUT" "Verdict: ready" "no risk block is ready"
fixtures
mutate pr '.description = "<!-- risk-assessment:start -->\n**Overall risk: ok**\n<!-- risk-assessment:end -->"'
run_merge 123 --json
assert_equal ready "$(json_field .verdict)" "a block without items is ready"
assert_equal '{"present":true,"total":0,"ticked":0,"unticked":0,"unreadable":false,"scoredAtCurrent":null,"untickedBlocking":false,"staleBlocking":false,"waivedUnticked":false,"waivedStale":false}' \
  "$(printf '%s' "$OUT" | jq -c '.checklist')" "no-items checklist"
fixtures
mutate pr '.description |= sub("scored at `aaaaaaa`"; "scored at `AAAAAAAAAAAAA`")'
run_merge 123 --json
assert_equal ready "$(json_field .verdict)" "a scored-at prefix of the head (any case) is current"
fixtures
mutate pr '.description |= gsub("\n"; "\r\n") | .description |= sub("\\[x\\]"; "[ ]")'
run_merge 123 --json
printf '%s' "$OUT" | jq -e '.reasons | map(.code) | index("checklist_unticked") != null' >/dev/null || fail "CRLF checklist boxes were not parsed"

# ── Waiver: only the two checklist reasons, never other reasons, never a box edit ──
fixtures
mutate pr '.description |= sub("\\[x\\]"; "[ ]")'
run_merge 123 --waive-checklist --json
assert_equal ready "$(json_field .verdict)" "waived unticked verdict"
assert_equal true "$(json_field .checklist.waivedUnticked)" "waivedUnticked"
assert_equal false "$(json_field .checklist.untickedBlocking)" "untickedBlocking after waiver"
assert_no_write "waived preview"
fixtures
mutate pr '.description |= sub("scored at `aaaaaaa`"; "scored at `ccccccc`")'
run_merge 123 --waive-checklist --json
assert_equal ready "$(json_field .verdict)" "waived stale verdict"
assert_equal true "$(json_field .checklist.waivedStale)" "waivedStale"
assert_equal false "$(json_field .checklist.waivedUnticked)" "waivedUnticked stays false for a stale-only checklist"
for case_filter in '.isDraft = true' '.description |= sub("<!-- risk-assessment:end -->"; "")' '.description += "\nCo-authored-by: Claude <noreply@anthropic.com>"'; do
  fixtures
  mutate pr ".description |= sub(\"\\\\[x\\\\]\"; \"[ ]\") | $case_filter"
  run_merge 123 --execute --head "$HEAD8" --waive-checklist
  assert_equal 1 "$STATUS" "waiver must not clear other reasons ($case_filter)"
  assert_no_write "waiver with another reason"
done

# ── Head pinning ─────────────────────────────────────────────────────
fixtures
run_merge 123 --execute --head deadbeef --json
assert_equal 1 "$STATUS" "wrong --head exit status"
assert_equal refused "$(json_field .result)" "wrong --head result"
printf '%s' "$OUT" | jq -e '.reasons | map(.code) | index("head_mismatch") != null' >/dev/null || fail "head_mismatch missing"
assert_no_write "wrong --head"

# The head can change between the verification and the write: the re-read cancels the merge.
fixtures
jq --arg c "$OTHER_SHA" '.lastMergeSourceCommit.commitId = $c' "$BASE_DIR/pr.json" > "$MOCK_DIR/pr.2.json"
run_merge 123 --execute --head "$HEAD8" --json
assert_equal 1 "$STATUS" "head changed before the write: exit status"
assert_equal refused "$(json_field .result)" "head changed result"
assert_no_write "head changed before the write"
fixtures
jq --arg c "$OTHER_SHA" '.lastMergeCommit.commitId = $c' "$BASE_DIR/pr.json" > "$MOCK_DIR/pr.2.json"
run_merge 123 --execute --head "$HEAD8"
assert_equal 1 "$STATUS" "merge commit changed before the write: exit status"
assert_has "$OUT" "after it was verified" "merge commit changed message"
assert_no_write "merge commit changed before the write"
fixtures
jq '.status = "abandoned"' "$BASE_DIR/pr.json" > "$MOCK_DIR/pr.2.json"
run_merge 123 --execute --head "$HEAD8"
assert_equal 1 "$STATUS" "status changed before the write: exit status"
assert_no_write "status changed before the write"

# ── --execute: pinned squash merge, request sequence, body, polling ──
fixtures
jq --arg c "$DONE_SHA" '.status = "completed" | .lastMergeCommit.commitId = $c' "$BASE_DIR/pr.json" > "$MOCK_DIR/pr.3.json"
run_merge 123 --execute --head "$HEAD_SHA" --interval 1 --timeout 5
assert_equal 0 "$STATUS" "--execute exit status: $OUT $ERR"
assert_has "$OUT" "Completed (squash). Merge commit: $DONE_SHA" "--execute prints the merge commit"
assert_requests "--execute" "GET $PR_URL
GET $EVALS_URL
GET $BUILDS_URL
GET $PR_URL
PATCH $PR_URL
GET $PR_URL"
BODY="$(cat "$MOCK_DIR/patch.body")"
assert_equal completed "$(printf '%s' "$BODY" | jq -r .status)" "PATCH status"
assert_equal squash "$(printf '%s' "$BODY" | jq -r .completionOptions.mergeStrategy)" "PATCH merge strategy"
assert_equal "$HEAD_SHA" "$(printf '%s' "$BODY" | jq -r .lastMergeSourceCommit.commitId)" "PATCH pins the verified head"
assert_equal true "$(printf '%s' "$BODY" | jq -r .completionOptions.deleteSourceBranch)" "PATCH deleteSourceBranch"
assert_equal true "$(printf '%s' "$BODY" | jq -r .completionOptions.transitionWorkItems)" "PATCH transitionWorkItems"
assert_equal "$(printf 'Add widget\n\nBody line\n\nTrailer text')" "$(printf '%s' "$BODY" | jq -r .completionOptions.mergeCommitMessage)" "merge message is the title plus the description without the risk block"
assert_equal '["completionOptions","lastMergeSourceCommit","status"]' "$(printf '%s' "$BODY" | jq -c 'keys')" "PATCH body keys"
for forbidden in bypass Bypass "Co-Authored" "co-authored" "Generated" "Claude" "risk-assessment" "Overall risk"; do
  assert_lacks "$BODY" "$forbidden" "PATCH body"
done
# The token never reaches argv or any output; the header goes through the private pipe.
assert_equal "$EXPECTED_BASIC" "$(sort -u "$MOCK_DIR/header.log")" "execute auth header"
for leak in "$AZURE_DEVOPS_PAT_WORK" "${EXPECTED_BASIC#Authorization: Basic }" "Authorization"; do
  assert_lacks "$(cat "$MOCK_DIR/argv.log")" "$leak" "curl argv"
  assert_lacks "$OUT$ERR" "$leak" "execute output"
done
assert_has "$(cat "$MOCK_DIR/argv.log")" "@/dev/fd/3" "auth descriptor"

# A lowercase or uppercase prefix of at least eight characters pins the same head.
fixtures
jq --arg c "$DONE_SHA" '.status = "completed" | .lastMergeCommit.commitId = $c' "$BASE_DIR/pr.json" > "$MOCK_DIR/pr.3.json"
run_merge 123 --execute --head "$(printf '%s' "$HEAD8" | "$REAL_TR" a-f A-F)" --interval 1 --timeout 5
assert_equal 0 "$STATUS" "uppercase --head prefix"

# --json result of --execute.
fixtures
jq --arg c "$DONE_SHA" '.status = "completed" | .lastMergeCommit.commitId = $c' "$BASE_DIR/pr.json" > "$MOCK_DIR/pr.3.json"
run_merge 123 --execute --head "$HEAD8" --json --interval 1 --timeout 5
assert_equal 0 "$STATUS" "--execute --json exit status"
assert_equal '["head","mergeCommit","organization","project","pullRequestId","reasons","repository","result","waivedChecklist"]' "$(printf '%s' "$OUT" | jq -c 'keys')" "--execute --json keys"
assert_equal completed "$(json_field .result)" "--execute --json result"
assert_equal "$DONE_SHA" "$(json_field .mergeCommit)" "--execute --json merge commit"
assert_equal "$HEAD_SHA" "$(json_field .head)" "--execute --json head"
assert_equal false "$(json_field .waivedChecklist)" "--execute --json waivedChecklist"

# Completion that is queued: poll until completed.
fixtures
jq --arg c "$DONE_SHA" '.status = "completed" | .lastMergeCommit.commitId = $c' "$BASE_DIR/pr.json" > "$MOCK_DIR/pr.4.json"
run_merge 123 --execute --head "$HEAD8" --interval 1 --timeout 10
assert_equal 0 "$STATUS" "queued completion exit status"
assert_equal 4 "$(grep -c '^GET .*pullrequests/123' "$MOCK_DIR/requests.log")" "poll repeated until completed"
assert_has "$OUT" "Merge commit: $DONE_SHA" "queued completion merge commit"

# A timeout never claims the PR is merged.
fixtures
run_merge 123 --execute --head "$HEAD8" --interval 1 --timeout 2
assert_equal 1 "$STATUS" "timeout exit status"
assert_has "$OUT" "not confirmed as merged" "timeout message"
assert_lacks "$OUT" "Completed" "timeout output"
assert_lacks "$OUT" "✅ Completed" "timeout does not claim success"
fixtures
run_merge 123 --execute --head "$HEAD8" --interval 1 --timeout 2 --json
assert_equal 1 "$STATUS" "timeout --json exit status"
assert_equal timeout "$(json_field .result)" "timeout --json result"
assert_equal null "$(json_field .mergeCommit)" "timeout --json merge commit"

# An abandoned PR is reported as such.
fixtures
jq '.status = "abandoned"' "$BASE_DIR/pr.json" > "$MOCK_DIR/pr.3.json"
run_merge 123 --execute --head "$HEAD8" --interval 1 --timeout 5 --json
assert_equal 1 "$STATUS" "abandoned exit status"
assert_equal abandoned "$(json_field .result)" "abandoned result"

# Server rejections surface a hint and stop without polling.
for http_case in "400:too long" "403:blocking policy" "500:may or may not"; do
  fixtures
  echo "${http_case%%:*}" > "$MOCK_DIR/patch.http"
  run_merge 123 --execute --head "$HEAD8" --interval 1 --timeout 2
  assert_equal 1 "$STATUS" "PATCH HTTP ${http_case%%:*} exit status"
  assert_has "$OUT" "${http_case#*:}" "PATCH HTTP ${http_case%%:*} hint"
  assert_equal PATCH "$(tail -n 1 "$MOCK_DIR/requests.log" | cut -d' ' -f1)" "PATCH HTTP ${http_case%%:*} is the last request"
  assert_lacks "$OUT" "Completed" "failed merge"
done
fixtures
echo 403 > "$MOCK_DIR/patch.http"
run_merge 123 --execute --head "$HEAD8" --json
assert_equal failed "$(json_field .result)" "PATCH failure --json result"

# A waived checklist lets the owner's decision through; the result records it.
fixtures
mutate pr '.description |= sub("\\[x\\]"; "[ ]")'
jq --arg c "$DONE_SHA" '.status = "completed" | .lastMergeCommit.commitId = $c' "$MOCK_DIR/pr.json" > "$MOCK_DIR/pr.3.json"
run_merge 123 --execute --head "$HEAD8" --waive-checklist --json --interval 1 --timeout 5
assert_equal 0 "$STATUS" "waived --execute exit status: $OUT"
assert_equal true "$(json_field .waivedChecklist)" "waivedChecklist recorded"
assert_lacks "$(cat "$MOCK_DIR/patch.body")" "[x]" "waiver does not rewrite boxes"
assert_lacks "$(cat "$MOCK_DIR/patch.body")" "[ ]" "waiver does not leak the checklist"

# ── --requeue-expired touches only expired, blocking, applicable Build evaluations ──
fixtures
E1="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1"
E2="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2"
E3="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee3"
E4="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee4"
E5="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee5"
cat > "$MOCK_DIR/evals.json" <<JSON
{"value":[
 {"evaluationId":"$E1","status":"rejected","configuration":{"isBlocking":true,"isEnabled":true,"type":{"displayName":"Build"},"settings":{"buildDefinitionId":7}},"context":{"buildId":501,"isExpired":true}},
 {"evaluationId":"$E2","status":"rejected","configuration":{"isBlocking":true,"isEnabled":true,"type":{"displayName":"Build"},"settings":{"buildDefinitionId":8}},"context":{"buildId":502,"isExpired":false}},
 {"evaluationId":"$E3","status":"rejected","configuration":{"isBlocking":true,"isEnabled":true,"type":{"displayName":"Minimum number of reviewers"},"settings":{}},"context":{"isExpired":true}},
 {"evaluationId":"$E4","status":"rejected","configuration":{"isBlocking":false,"isEnabled":true,"type":{"displayName":"Build"},"settings":{"buildDefinitionId":9}},"context":{"buildId":503,"isExpired":true}},
 {"evaluationId":"$E5","status":"notApplicable","configuration":{"isBlocking":true,"isEnabled":true,"type":{"displayName":"Build"},"settings":{"buildDefinitionId":10}},"context":{"buildId":504,"isExpired":true}}]}
JSON
run_merge 123 --requeue-expired
assert_equal 0 "$STATUS" "--requeue-expired exit status: $OUT $ERR"
assert_equal "$API_BASE/_apis/policy/evaluations/$E1?api-version=7.1-preview.1" "$(cat "$MOCK_DIR/requeue.log")" "only the expired blocking Build evaluation was requeued"
assert_equal '{}' "$(cat "$MOCK_DIR/requeue.body")" "requeue body"
if "$REAL_GREP" -q '^PATCH .*pullrequests' "$MOCK_DIR/requests.log"; then fail "--requeue-expired patched the pull request"; fi
assert_equal 1 "$(grep -c '^PATCH ' "$MOCK_DIR/requests.log")" "--requeue-expired wrote exactly one request"
assert_has "$OUT" "Requeued 1 expired build evaluation" "requeue summary"
assert_has "$OUT" "Verdict: blocked" "requeue prints a fresh preview afterwards"
assert_has "$OUT" "build_expired" "the preview still reports the expired build until the new build finishes"
assert_has "$OUT" "policy_not_approved: Required policy \"Minimum number of reviewers\" is rejected." "other rejected policies are reported"

fixtures
run_merge 123 --requeue-expired
assert_has "$OUT" "No expired build evaluations to requeue." "nothing to requeue"
assert_no_write "requeue with nothing expired"

fixtures
mutate pr '.status = "completed"'
run_merge 123 --requeue-expired
assert_equal 1 "$STATUS" "requeue of a non-active PR"
assert_no_write "requeue of a non-active PR"

# The preview alone never requeues, even with an expired build.
fixtures
mutate evals '.value[0].context.isExpired = true'
run_merge 123
assert_no_write "preview with an expired build"

# ── API failures and context errors ──────────────────────────────────
fixtures
echo 500 > "$MOCK_DIR/pr.fail"
run_merge 123 --execute --head "$HEAD8"
[ "$STATUS" -ne 0 ] || fail "an API failure was treated as a verdict"
assert_no_write "API failure"
assert_lacks "$OUT$ERR" "error-body-secret" "API failure output"
assert_lacks "$OUT$ERR" "$AZURE_DEVOPS_PAT_WORK" "API failure output"

fixtures
OUT="$(cd "$MERGE_REPO" && PATH="$MOCK_BIN:$BASE_BIN" MOCK_DIR="$MOCK_DIR" AZURE_DEVOPS_ORG=redirected-org "$PR" merge 123 2>&1)"
STATUS=$?
[ "$STATUS" -ne 0 ] || fail "AZURE_DEVOPS_ORG redirected pr merge"
assert_has "$OUT" "does not match the selected repository organization" "organization override message"
[ ! -s "$MOCK_DIR/requests.log" ] || fail "organization mismatch sent a request"

# ── GitHub remotes are unsupported, with a pointer to the skill ──────
MERGE_REPO="$GITHUB_REPO"
for args in "123" "123 --execute --head $HEAD8" "123 --requeue-expired"; do
  fixtures
  # shellcheck disable=SC2086 # word splitting of the fixed test arguments is intended
  run_merge $args
  assert_equal 1 "$STATUS" "GitHub remote exit status for '$args'"
  assert_has "$ERR" "unsupported for GitHub remotes" "GitHub unsupported message"
  assert_has "$ERR" "merge-pr skill" "GitHub message points to the skill"
  assert_equal "" "$(cat "$MOCK_DIR/requests.log")" "GitHub remote sent a request for '$args'"
done
MERGE_REPO="$AZURE_REPO"

echo "pr merge regression checks passed"
