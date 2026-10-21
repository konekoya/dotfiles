#!/bin/bash
# Description: Regression coverage for shared Azure DevOps helpers and consumers

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HELPER="$REPO_ROOT/lib/azure-devops.sh"
SCRIPTS_UNDER_TEST=(ado-rest pr pr-comments pr-status repo submit-pr local-env)
REAL_GIT="$(command -v git)" || exit 1
REAL_JQ="$(command -v jq)" || exit 1
REAL_BASE64="$(command -v base64)" || exit 1
REAL_TR="$(command -v tr)" || exit 1
REAL_HEAD="$(command -v head)" || exit 1
REAL_TAIL="$(command -v tail)" || exit 1
REAL_SED="$(command -v sed)" || exit 1
REAL_GREP="$(command -v grep)" || exit 1
REAL_DIRNAME="$(command -v dirname)" || exit 1
REAL_RM="$(command -v rm)" || exit 1
REAL_FIND="$(command -v find)" || exit 1
REAL_CAT="$(command -v cat)" || exit 1
REAL_CHMOD="$(command -v chmod)" || exit 1
REAL_MKTEMP="$(command -v mktemp)" || exit 1
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/azure-devops-regression.XXXXXX")" || exit 1
BASE_BIN="$TEST_ROOT/base-bin"
AZ_BIN="$TEST_ROOT/az-bin"
SCRIPT_BIN="$TEST_ROOT/script-bin"
HELPER_OUTPUT_FILE="$TEST_ROOT/helper-output"
mkdir -p "$BASE_BIN" "$AZ_BIN" "$SCRIPT_BIN" "$TEST_ROOT/no-git" || exit 1

# Keep caller credentials out of every fixture invocation; all auth below is synthetic.
unset AZURE_DEVOPS_ORG AZURE_DEVOPS_PROFILE AZURE_DEVOPS_PAT AZURE_DEVOPS_PAT_WORK AZURE_DEVOPS_PAT_PERSONAL AZURE_DEVOPS_PAT_WORK_PROD

# Scripts locate alias/.env from their own path. Run copies inside a fixture so the
# developer's real alias/.env is never read; tests that need one write FIXTURE_ENV.
FIXTURE_DOTFILES="$TEST_ROOT/dotfiles"
FIXTURE_ENV="$FIXTURE_DOTFILES/alias/.env"
mkdir -p "$FIXTURE_DOTFILES/scripts" "$FIXTURE_DOTFILES/lib" "$FIXTURE_DOTFILES/alias" || exit 1
cp "$REPO_ROOT"/lib/*.sh "$FIXTURE_DOTFILES/lib/" || exit 1
for script_name in "${SCRIPTS_UNDER_TEST[@]}"; do
  cp "$REPO_ROOT/scripts/$script_name" "$FIXTURE_DOTFILES/scripts/$script_name" || exit 1
done
PR_COMMENTS="$FIXTURE_DOTFILES/scripts/pr-comments"
PR_STATUS="$FIXTURE_DOTFILES/scripts/pr-status"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

link_tool() {
  local tool_path="$1"
  local tool_name="${tool_path##*/}"
  ln -s "$tool_path" "$BASE_BIN/$tool_name" || fail "could not add '$tool_name' to test PATH"
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

assert_no_secret() {
  local output="$1"
  local secret="$2"
  case "$output" in
    *"$secret"*) fail "output exposed a credential" ;;
  esac
}

assert_parse() {
  local remote_url="$1"
  local expected_org="$2"
  local expected_project="$3"
  local expected_repo="$4"
  local output status

  ado_parse_remote "$remote_url" > "$HELPER_OUTPUT_FILE" 2>&1
  status=$?
  output="$(cat "$HELPER_OUTPUT_FILE")"
  [ "$status" -eq 0 ] || fail "could not parse supported remote '$remote_url'"
  [ -z "$output" ] || fail "remote parser printed unexpected output"
  assert_equal "$expected_org" "$ADO_ORG" "parsed org"
  assert_equal "$expected_project" "$ADO_PROJECT" "parsed project"
  assert_equal "$expected_repo" "$ADO_REPO" "parsed repository"
  assert_equal "$remote_url" "$ADO_REMOTE_URL" "parsed remote URL"
}

assert_invalid_parse() {
  local remote_url="$1"
  local output status

  ado_parse_remote "$remote_url" > "$HELPER_OUTPUT_FILE" 2>&1
  status=$?
  output="$(cat "$HELPER_OUTPUT_FILE")"
  [ "$status" -ne 0 ] || fail "malformed remote was accepted: '$remote_url'"
  [ -z "$output" ] || fail "remote parser printed diagnostics for malformed input"
  [ -z "$ADO_ORG" ] && [ -z "$ADO_PROJECT" ] && [ -z "$ADO_REPO" ] || fail "failed parser left stale identifiers"
  [ -z "$ADO_REMOTE_URL" ] || fail "failed parser retained the raw remote URL"
}

make_repo() {
  local name="$1"
  local remote_url="${2-}"
  local repo_dir="$TEST_ROOT/$name"
  mkdir -p "$repo_dir" || fail "could not create repository '$name'"
  "$REAL_GIT" -C "$repo_dir" init -q || fail "could not initialize repository '$name'"
  if [ -n "$remote_url" ]; then
    "$REAL_GIT" -C "$repo_dir" remote add origin "$remote_url" || fail "could not add origin for '$name'"
  fi
  printf '%s' "$repo_dir"
}

for tool_path in "$REAL_GIT" "$REAL_JQ" "$REAL_BASE64" "$REAL_TR" "$REAL_HEAD" "$REAL_TAIL" "$REAL_SED" "$REAL_GREP" "$REAL_DIRNAME" "$REAL_RM" "$REAL_FIND" "$REAL_CAT" "$REAL_CHMOD" "$REAL_MKTEMP"; do
  link_tool "$tool_path"
done

cat > "$AZ_BIN/az" <<'EOF'
#!/bin/bash

if [ -n "${ADO_TEST_AZ_CALLED_FILE:-}" ]; then
  : > "$ADO_TEST_AZ_CALLED_FILE"
fi

if [ "$*" = 'account show --query {user:user.name,tenantId:tenantId} -o json' ]; then
  [ "${ADO_TEST_AZ_MODE:-token}" != account-fail ] || exit 1
  printf '{"user":"%s","tenantId":"%s"}\n' \
    "${ADO_TEST_AZ_USER:-user@example.invalid}" "${ADO_TEST_AZ_TENANT:-11111111-1111-4111-8111-111111111111}"
  exit 0
fi

expected="account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --tenant ${ADO_TEST_AZ_TENANT:-11111111-1111-4111-8111-111111111111} --query accessToken -o tsv"
[ "$*" = "$expected" ] || exit 9
case "${ADO_TEST_AZ_MODE:-token}" in
  token) printf '%s\n' "${ADO_TEST_AZ_TOKEN:-regression-access-token}" ;;
  empty) : ;;
  fail) exit 1 ;;
esac
EOF
chmod +x "$AZ_BIN/az" || fail "could not make az shim executable"

cat > "$SCRIPT_BIN/curl" <<'EOF'
#!/bin/bash

auth_header=""
auth_header_arg=""
url=""
method=GET
connect_timeout=""
max_time=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H)
      shift
      case "${1-}" in
        @*)
          auth_header_arg="$1"
          auth_path="${1#@}"
          [ -p "$auth_path" ] || exit 10
          auth_header="$(cat "$auth_path")"
          ;;
        Authorization:*) auth_header="$1" ;;
      esac
      ;;
    --connect-timeout) shift; connect_timeout="$1" ;;
    --max-time) shift; max_time="$1" ;;
    -X) shift; method="$1" ;;
    -d)
      shift
      if [ -n "${ADO_TEST_CURL_BODY_FILE:-}" ]; then
        printf '%s' "$1" > "$ADO_TEST_CURL_BODY_FILE"
      fi
      ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
[ "$connect_timeout" = 10 ] && [ "$max_time" = 60 ] || exit 9

if [ -n "${ADO_TEST_CURL_HEADER_FILE:-}" ]; then
  printf '%s\n' "$auth_header" > "$ADO_TEST_CURL_HEADER_FILE"
fi
if [ -n "${ADO_TEST_CURL_AUTH_ARG_FILE:-}" ]; then
  printf '%s\n' "$auth_header_arg" > "$ADO_TEST_CURL_AUTH_ARG_FILE"
fi
if [ -n "${ADO_TEST_CURL_METHOD_FILE:-}" ]; then
  printf '%s\n' "$method" > "$ADO_TEST_CURL_METHOD_FILE"
fi
if [ -n "${ADO_TEST_CURL_URLS_FILE:-}" ]; then
  printf '%s\n' "$url" >> "$ADO_TEST_CURL_URLS_FILE"
fi

case "$url" in
  https://api.clickup.com/*)
    if [ -n "${ADO_TEST_CURL_CLICKUP_HEADER_FILE:-}" ]; then
      printf '%s\n' "$auth_header" > "$ADO_TEST_CURL_CLICKUP_HEADER_FILE"
    fi
    ;;
esac

if [ "${ADO_TEST_CURL_MODE:-}" = transport-failure ]; then exit 28; fi
if [ "${ADO_TEST_CURL_MODE:-}" = denied ]; then
  printf '{"message":"error-body-secret"}\n401\n'
  exit 0
fi
if [ "${ADO_TEST_CURL_MODE:-}" = invalid-json ]; then
  printf 'invalid-json-secret\n200\n'
  exit 0
fi
if [ "${ADO_TEST_CURL_MODE:-}" = empty-success ]; then
  printf '\n204\n'
  exit 0
fi

case "$url" in
  */_apis/connectionData*)
    printf '%s\n' '{"authenticatedUser":{"id":"test-user"}}'
    ;;
  */_apis/projects*)
    printf '%s\n' '{"value":[{"name":"Project With Spaces"}]}'
    ;;
  */threads*)
    printf '%s\n' '{"value":[]}'
    ;;
  */_apis/git/repositories/*/pullrequests/[0-9]*\?*)
    printf '%s\n' '{"title":"Regression PR","description":"Existing description","mergeStatus":"succeeded","createdBy":{"displayName":"Test Author"},"sourceRefName":"refs/heads/feature/test","targetRefName":"refs/heads/main","repository":{"id":"repo-id","project":{"id":"project-id"}}}'
    ;;
  *pullrequests\?*)
    if [ "$method" = POST ]; then
      printf '%s\n' '{"pullRequestId":456}'
    elif [ "${ADO_TEST_CURL_MODE:-}" = repo-pr ]; then
      printf '%s\n' '{"value":[{"pullRequestId":123}]}'
    else
      printf '%s\n' '{"value":[]}'
    fi
    ;;
  https://api.github.com/*)
    printf '%s\n' '[{"number":42}]'
    ;;
  */_apis/policy/evaluations*)
    if [ "${ADO_TEST_CURL_MODE:-}" = invalid-policies ]; then
      printf '%s\n' '{"message":"missing-policy-array"}'
    elif [ "${ADO_TEST_CURL_MODE:-}" = failed-build ]; then
      printf '%s\n' '{"value":[{"configuration":{"type":{"displayName":"Build"}},"status":"rejected","context":{"buildId":7}}]}'
    else
      printf '%s\n' '{"value":[]}'
    fi
    ;;
  */timeline*)
    printf '%s\n' '{"records":[{"result":"failed","type":"Task","name":"Regression task","log":{"id":8}}]}'
    ;;
  */logs/*)
    printf 'ordinary build output\n'
    ;;
  *)
    printf '%s\n' '{"value":[]}'
    ;;
esac
printf '\n200\n'
EOF
chmod +x "$SCRIPT_BIN/curl" || fail "could not make curl shim executable"

# shellcheck source=../lib/azure-devops.sh
source "$HELPER" || fail "could not source shared helper"

# Remote parsing accepts the three supported Azure DevOps URL formats.
assert_parse 'git@ssh.dev.azure.com:v3/my-org/my-project/my-repo' my-org my-project my-repo
assert_parse 'git@ssh.dev.azure.com:v3/my-org/my-project/my-repo.git' my-org my-project my-repo
assert_parse 'https://dev.azure.com/my-org/my-project/_git/my-repo' my-org my-project my-repo
assert_parse 'https://user@dev.azure.com/my-org/my-project/_git/my-repo' my-org my-project my-repo
assert_parse 'ssh://git@ssh.dev.azure.com/v3/my-org/my-project/my-repo' my-org my-project my-repo
assert_parse 'https://my-org.visualstudio.com/my-project/_git/my-repo' my-org my-project my-repo
assert_parse 'https://user@my-org.visualstudio.com/my-project/_git/my-repo' my-org my-project my-repo
assert_invalid_parse ''
assert_invalid_parse 'git@ssh.dev.azure.com:v3/my-org/my-project'
assert_invalid_parse 'https://my-org.visualstudio.com/my-project/my-repo'
assert_invalid_parse 'https://my-org:443.visualstudio.com/my-project/_git/my-repo'
assert_invalid_parse 'https://github.com/example/my-repo.git'
assert_invalid_parse 'https://user@dev.azure.com/my-org/my-project/_git/repo?query=1'

# Repository context resolves the selected fetch/push pair and rejects unsafe or ambiguous destinations.
PREVIOUS_DIR="$PWD"
NO_REPO_DIR="$TEST_ROOT/no-git"
cd "$NO_REPO_DIR" || fail "could not enter non-repository directory"
if ado_resolve_repo_context; then fail "context resolution succeeded outside a Git repository"; fi
assert_equal 'Not inside a Git repository.' "$ADO_CONTEXT_ERROR" "outside repository error"

NO_ORIGIN_REPO="$(make_repo no-origin)"
cd "$NO_ORIGIN_REPO" || fail "could not enter no-origin repository"
if ado_resolve_repo_context; then fail "context resolution succeeded without origin"; fi
case "$ADO_CONTEXT_ERROR" in *"Selected Git remote is missing"*) ;; *) fail "missing origin error was not actionable" ;; esac

NON_AZURE_REPO="$(make_repo non-azure-context https://github.com/example/project.git)"
cd "$NON_AZURE_REPO" || fail "could not enter non-Azure repository"
if ado_resolve_repo_context; then fail "context resolution accepted a non-Azure origin"; fi
assert_equal 'Selected Git remote is not a recognized Azure DevOps remote.' "$ADO_CONTEXT_ERROR" "non-Azure origin error"

UNSUPPORTED_REPO="$(make_repo unsupported-with-userinfo 'https://synthetic-user:credential-sentinel@unsupported.example.invalid/org/project/repo')"
cd "$UNSUPPORTED_REPO" || fail "could not enter unsupported remote repository"
if ado_resolve_remote_context; then fail "unsupported remote was accepted"; fi
assert_no_secret "$ADO_REMOTE_ERROR" credential-sentinel
case "$ADO_REMOTE_ERROR" in *unsupported\ host*) ;; *) fail "unsupported remote error was not actionable" ;; esac

SSH_REPO="$(make_repo ssh-context git@ssh.dev.azure.com:v3/context-org/context-project/context-repo)"
"$REAL_GIT" -C "$SSH_REPO" config azure-devops.work.organization context-org
"$REAL_GIT" -C "$SSH_REPO" config azure-devops.work.auth pat
"$REAL_GIT" -C "$SSH_REPO" config azure-devops.profile work
cd "$SSH_REPO" || fail "could not enter SSH repository"
unset AZURE_DEVOPS_ORG
ado_resolve_repo_context || fail "could not resolve SSH repository context"
assert_equal '' "$ADO_CONTEXT_ERROR" "successful context resolution clears stale error"
assert_equal context-org "$ADO_ORG" "SSH context org"
assert_equal context-project "$ADO_PROJECT" "SSH context project"
assert_equal context-repo "$ADO_REPO" "SSH context repository"
assert_equal 'git@ssh.dev.azure.com:v3/context-org/context-project/context-repo' "$ADO_REMOTE_URL" "SSH context remote"
assert_equal work "$ADO_PROFILE" "selected work profile"

HTTPS_REPO="$(make_repo https-context 'https://dev.azure.com/https-org/https-project/_git/https-repo')"
"$REAL_GIT" -C "$HTTPS_REPO" config azure-devops.personal.organization https-org
"$REAL_GIT" -C "$HTTPS_REPO" config azure-devops.personal.auth pat
"$REAL_GIT" -C "$HTTPS_REPO" config azure-devops.profile personal
cd "$HTTPS_REPO" || fail "could not enter HTTPS repository"
ado_resolve_repo_context || fail "could not resolve HTTPS repository context"
assert_equal https-org "$ADO_ORG" "HTTPS context org"
assert_equal https-project "$ADO_PROJECT" "HTTPS context project"
assert_equal https-repo "$ADO_REPO" "HTTPS context repository"
assert_equal personal "$ADO_PROFILE" "selected personal profile"

AZURE_DEVOPS_ORG=override-org
export AZURE_DEVOPS_ORG
if ado_resolve_repo_context; then fail "organization override redirected the repository"; fi
case "$ADO_CONTEXT_ERROR" in *"does not match the selected repository organization"*) ;; *) fail "organization mismatch error was not actionable" ;; esac
unset AZURE_DEVOPS_ORG

# A non-origin remote can be selected, but fetch and push URLs must identify the same repository.
CUSTOM_REPO="$(make_repo custom-remote https://github.com/example/unrelated.git)"
"$REAL_GIT" -C "$CUSTOM_REPO" remote add azure 'https://dev.azure.com/custom-org/Custom%20Project/_git/custom-repo'
"$REAL_GIT" -C "$CUSTOM_REPO" config azure-devops.custom.organization custom-org
"$REAL_GIT" -C "$CUSTOM_REPO" config azure-devops.custom.auth pat
"$REAL_GIT" -C "$CUSTOM_REPO" config azure-devops.profile custom
"$REAL_GIT" -C "$CUSTOM_REPO" config azure-devops.remote azure
cd "$CUSTOM_REPO" || fail "could not enter custom-remote repository"
ado_resolve_repo_context || fail "could not resolve configured non-origin remote"
assert_equal custom-org "$ADO_ORG" "custom remote organization"
assert_equal 'Custom%20Project' "$ADO_PROJECT" "encoded project path"
assert_equal azure "$ADO_REMOTE_NAME" "selected non-origin remote"
"$REAL_GIT" remote set-url --add azure 'https://dev.azure.com/custom-org/another-project/_git/another-repo'
if ado_resolve_repo_context; then fail "multiple fetch URLs were accepted"; fi
case "$ADO_CONTEXT_ERROR" in *"multiple fetch URLs"*) ;; *) fail "multiple fetch URL error was not actionable" ;; esac
"$REAL_GIT" remote set-url --delete azure 'https://dev.azure.com/custom-org/another-project/_git/another-repo'
"$REAL_GIT" remote set-url --push azure 'https://dev.azure.com/other-org/Custom%20Project/_git/custom-repo'
if ado_resolve_repo_context; then fail "mismatched fetch and push destinations were accepted"; fi
case "$ADO_CONTEXT_ERROR" in *"conflicting fetch and push destinations"*) ;; *) fail "fetch/push mismatch error was not actionable" ;; esac
cd "$PREVIOUS_DIR" || fail "could not restore working directory"

# Profile PATs are isolated by name and bind to a single organization.
cd "$HTTPS_REPO" || fail "could not enter profile authentication repository"
ado_resolve_repo_context || fail "could not resolve personal profile before authentication"
AZURE_DEVOPS_PAT_PERSONAL='synthetic-personal-pat'
AZURE_DEVOPS_PAT_WORK='synthetic-work-pat'
export AZURE_DEVOPS_PAT_PERSONAL AZURE_DEVOPS_PAT_WORK
export ADO_TEST_AZ_CALLED_FILE="$TEST_ROOT/az-was-called"
rm -f "$ADO_TEST_AZ_CALLED_FILE"
saved_path="$PATH"
PATH="$AZ_BIN:$BASE_BIN"
ado_get_auth_header > "$HELPER_OUTPUT_FILE" 2>&1
auth_status=$?
PATH="$saved_path"
auth_output="$(cat "$HELPER_OUTPUT_FILE")"
[ "$auth_status" -eq 0 ] || fail "profile PAT authentication failed"
expected_basic="Authorization: Basic $(printf ':%s' "$AZURE_DEVOPS_PAT_PERSONAL" | "$REAL_BASE64" 2>/dev/null | "$REAL_TR" -d '\r\n')"
assert_equal "$expected_basic" "$ADO_AUTH_HEADER" "PAT authorization header"
[ ! -e "$ADO_TEST_AZ_CALLED_FILE" ] || fail "Azure CLI was called despite PAT precedence"
assert_no_secret "$auth_output" "$AZURE_DEVOPS_PAT_PERSONAL"
[ -z "$auth_output" ] || fail "profile PAT auth helper printed output"

# A mismatched organization profile fails before auth, and no other profile PAT is used.
ADO_ORG=other-org
if ado_get_auth_header; then fail "profile PAT was used for the wrong organization"; fi
case "$ADO_AUTH_ERROR" in *"profile does not match the resolved repository organization"*) ;; *) fail "profile mismatch error was not actionable" ;; esac
ADO_ORG=https-org

# Legacy single-org PAT remains available only with a matching explicit organization.
ADO_PROFILE=""
AZURE_DEVOPS_ORG=https-org
AZURE_DEVOPS_PAT='synthetic-legacy-pat'
export AZURE_DEVOPS_ORG AZURE_DEVOPS_PAT
ado_get_auth_header || fail "matching legacy PAT authentication failed"
expected_basic="Authorization: Basic $(printf ':%s' "$AZURE_DEVOPS_PAT" | "$REAL_BASE64" 2>/dev/null | "$REAL_TR" -d '\r\n')"
assert_equal "$expected_basic" "$ADO_AUTH_HEADER" "legacy PAT authorization header"
unset AZURE_DEVOPS_PAT AZURE_DEVOPS_ORG

# With an organization but no PAT, the helper does not fall back to an unpinned CLI account.
ADO_PROFILE=""
AZURE_DEVOPS_ORG=https-org
export AZURE_DEVOPS_ORG
PATH="$AZ_BIN:$BASE_BIN"
rm -f "$ADO_TEST_AZ_CALLED_FILE"
ado_get_auth_header > "$HELPER_OUTPUT_FILE" 2>&1
auth_status=$?
PATH="$saved_path"
auth_output="$(cat "$HELPER_OUTPUT_FILE")"
 [ "$auth_status" -ne 0 ] || fail "authentication succeeded with an unpinned Azure CLI account"
case "$ADO_AUTH_ERROR" in *"Legacy Azure CLI fallback is disabled"*) ;; *) fail "unbound Azure CLI error was not actionable" ;; esac
[ -z "$ADO_AUTH_HEADER" ] || fail "missing az left an auth header"
[ -z "$auth_output" ] || fail "missing az auth printed output"
[ ! -e "$ADO_TEST_AZ_CALLED_FILE" ] || fail "unbound Azure CLI fallback was called"
unset AZURE_DEVOPS_ORG

# Azure CLI profiles require matching account metadata and token tenant/object ID claims.
"$REAL_GIT" -C "$HTTPS_REPO" config azure-devops.cli.organization https-org
"$REAL_GIT" -C "$HTTPS_REPO" config azure-devops.cli.auth azure-cli
"$REAL_GIT" -C "$HTTPS_REPO" config azure-devops.cli.tenant 11111111-1111-4111-8111-111111111111
"$REAL_GIT" -C "$HTTPS_REPO" config azure-devops.cli.user user@example.invalid
"$REAL_GIT" -C "$HTTPS_REPO" config azure-devops.cli.object-id 22222222-2222-4222-8222-222222222222
"$REAL_GIT" -C "$HTTPS_REPO" config azure-devops.profile cli
cd "$HTTPS_REPO" || fail "could not enter Azure CLI profile repository"
ado_resolve_repo_context || fail "could not bind Azure CLI profile"
payload=$(jq -cn --arg tid "$ADO_PROFILE_TENANT" --arg oid "$ADO_PROFILE_OBJECT_ID" '{tid:$tid,oid:$oid}')
payload_encoded=$(printf '%s' "$payload" | "$REAL_BASE64" | "$REAL_TR" '+/' '-_' | "$REAL_TR" -d '\r\n=')
export ADO_TEST_AZ_TOKEN="header.${payload_encoded}.signature"
export ADO_TEST_AZ_TENANT="$ADO_PROFILE_TENANT" ADO_TEST_AZ_USER="$ADO_PROFILE_USER"
export ADO_TEST_AZ_MODE=token
PATH="$AZ_BIN:$BASE_BIN"
rm -f "$ADO_TEST_AZ_CALLED_FILE"
ado_get_auth_header > "$HELPER_OUTPUT_FILE" 2>&1
auth_status=$?
PATH="$saved_path"
auth_output="$(cat "$HELPER_OUTPUT_FILE")"
[ "$auth_status" -eq 0 ] || fail "pinned Azure CLI profile failed: $ADO_AUTH_ERROR"
assert_equal '' "$ADO_AUTH_ERROR" "successful authentication clears stale error"
[ -e "$ADO_TEST_AZ_CALLED_FILE" ] || fail "pinned Azure CLI profile was not called"
[ -z "$auth_output" ] || fail "Azure CLI auth helper printed output"
assert_no_secret "$auth_output" "$ADO_TEST_AZ_TOKEN"

ADO_TEST_AZ_TENANT=33333333-3333-4333-8333-333333333333
export ADO_TEST_AZ_TENANT
PATH="$AZ_BIN:$BASE_BIN"
ado_get_auth_header > "$HELPER_OUTPUT_FILE" 2>&1
auth_status=$?
PATH="$saved_path"
auth_output="$(cat "$HELPER_OUTPUT_FILE")"
 [ "$auth_status" -ne 0 ] || fail "Azure CLI token from another tenant was accepted"
case "$ADO_AUTH_ERROR" in *"active Azure CLI account does not match"*) ;; *) fail "Azure CLI account mismatch was not actionable: $ADO_AUTH_ERROR" ;; esac
assert_no_secret "$auth_output" "$ADO_TEST_AZ_TOKEN"

ADO_TEST_AZ_TENANT="$ADO_PROFILE_TENANT"
export ADO_TEST_AZ_TENANT
payload=$(jq -cn --arg tid "$ADO_PROFILE_TENANT" --arg oid 33333333-3333-4333-8333-333333333333 '{tid:$tid,oid:$oid}')
payload_encoded=$(printf '%s' "$payload" | "$REAL_BASE64" | "$REAL_TR" '+/' '-_' | "$REAL_TR" -d '\r\n=')
ADO_TEST_AZ_TOKEN="header.${payload_encoded}.signature"
export ADO_TEST_AZ_TOKEN
PATH="$AZ_BIN:$BASE_BIN"
ado_get_auth_header > "$HELPER_OUTPUT_FILE" 2>&1
auth_status=$?
PATH="$saved_path"
auth_output="$(cat "$HELPER_OUTPUT_FILE")"
[ "$auth_status" -ne 0 ] || fail "Azure CLI token with another user object ID was accepted"
case "$ADO_AUTH_ERROR" in *"token claims do not match"*) ;; *) fail "Azure CLI token claim mismatch was not actionable" ;; esac
assert_no_secret "$auth_output" "$ADO_TEST_AZ_TOKEN"
unset ADO_TEST_AZ_MODE ADO_TEST_AZ_TOKEN ADO_TEST_AZ_TENANT ADO_TEST_AZ_USER

# Consumer regression: Azure scripts select a profile from a canonical no-user HTTPS remote.
SCRIPT_REPO="$(make_repo script-consumers https://dev.azure.com/script-org/script-project/_git/script-repo)"
"$REAL_GIT" -C "$SCRIPT_REPO" config azure-devops.work.organization script-org
"$REAL_GIT" -C "$SCRIPT_REPO" config azure-devops.work.auth pat
"$REAL_GIT" -C "$SCRIPT_REPO" config azure-devops.personal.organization personal-org
"$REAL_GIT" -C "$SCRIPT_REPO" config azure-devops.personal.auth pat
"$REAL_GIT" -C "$SCRIPT_REPO" config azure-devops.profile work
NON_AZURE_SCRIPT_REPO="$(make_repo script-non-azure https://github.com/example/not-azure.git)"
SCRIPT_HEADER_FILE="$TEST_ROOT/curl-header"
SCRIPT_AUTH_ARG_FILE="$TEST_ROOT/curl-auth-arg"
SCRIPT_METHOD_FILE="$TEST_ROOT/curl-method"
SCRIPT_URLS_FILE="$TEST_ROOT/curl-urls"

for script in "$PR_COMMENTS" "$PR_STATUS"; do
  case "$script" in
    */pr-comments) label='pr-comments' ;;
    */pr-status) label='pr-status' ;;
  esac
  cd "$NON_AZURE_SCRIPT_REPO" || fail "could not enter non-Azure consumer repository"
  PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" \
    ADO_TEST_CURL_HEADER_FILE="$SCRIPT_HEADER_FILE" \
    ADO_TEST_CURL_URLS_FILE="$SCRIPT_URLS_FILE" \
    AZURE_DEVOPS_PAT_WORK='' AZURE_DEVOPS_ORG='' \
    "$script" 123 > "$TEST_ROOT/$label-non-azure-output" 2>&1
  script_status=$?
  [ "$script_status" -ne 0 ] || fail "$label accepted a non-Azure repository"
  "$REAL_GREP" -Fq 'Selected Git remote is not a recognized Azure DevOps remote.' "$TEST_ROOT/$label-non-azure-output" || fail "$label did not report the non-Azure origin clearly: $(cat "$TEST_ROOT/$label-non-azure-output")"
done

cd "$SCRIPT_REPO" || fail "could not enter valid consumer repository"
export ADO_TEST_CURL_HEADER_FILE="$SCRIPT_HEADER_FILE"
export ADO_TEST_CURL_AUTH_ARG_FILE="$SCRIPT_AUTH_ARG_FILE"
export ADO_TEST_CURL_METHOD_FILE="$SCRIPT_METHOD_FILE"
export ADO_TEST_CURL_URLS_FILE="$SCRIPT_URLS_FILE"
export ADO_TEST_AZ_CALLED_FILE="$TEST_ROOT/script-az-was-called"
rm -f "$SCRIPT_HEADER_FILE" "$SCRIPT_AUTH_ARG_FILE" "$SCRIPT_URLS_FILE" "$ADO_TEST_AZ_CALLED_FILE"
AZURE_DEVOPS_PAT_WORK='synthetic-script-work-pat'
AZURE_DEVOPS_PAT_PERSONAL='synthetic-script-personal-pat'
export AZURE_DEVOPS_PAT_WORK AZURE_DEVOPS_PAT_PERSONAL
export TMPDIR="$TEST_ROOT"

# ado-rest validates inputs, reports safe repository context, and pipes the auth header.
context_json="$(PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$FIXTURE_DOTFILES/scripts/ado-rest" context 2>&1)" || fail "ado-rest context failed: $context_json"
assert_equal script-org "$(printf '%s' "$context_json" | jq -r '.organization')" "ado-rest organization context"
assert_equal script-project "$(printf '%s' "$context_json" | jq -r '.project')" "ado-rest project context"
assert_equal script-repo "$(printf '%s' "$context_json" | jq -r '.repository')" "ado-rest repository context"
rm -f "$SCRIPT_HEADER_FILE" "$SCRIPT_AUTH_ARG_FILE" "$SCRIPT_URLS_FILE"
PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$FIXTURE_DOTFILES/scripts/ado-rest" GET '/_apis/git/repositories/script-repo/pullrequests?api-version=7.1' > /dev/null || fail "ado-rest GET failed"
assert_equal '@/dev/fd/3' "$(cat "$SCRIPT_AUTH_ARG_FILE")" "ado-rest curl auth descriptor"
assert_no_secret "$(cat "$SCRIPT_AUTH_ARG_FILE")" "$AZURE_DEVOPS_PAT_WORK"
if PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$FIXTURE_DOTFILES/scripts/ado-rest" GET 'https://dev.azure.com/other-org/_apis/projects' > /dev/null 2>&1; then
  fail "ado-rest accepted an absolute URL"
fi
if PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$FIXTURE_DOTFILES/scripts/ado-rest" GET '/_apis/projects?access_token=synthetic' > /dev/null 2>&1; then
  fail "ado-rest accepted a credential query parameter"
fi
if PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$FIXTURE_DOTFILES/scripts/ado-rest" POST '/_apis/test' 'not-json' > /dev/null 2>&1; then
  fail "ado-rest accepted an invalid JSON body"
fi
export ADO_TEST_CURL_MODE=empty-success
PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$FIXTURE_DOTFILES/scripts/ado-rest" DELETE '/_apis/git/repositories/script-repo/pullrequests/123?api-version=7.1' > /dev/null || fail "ado-rest rejected a successful empty response"
assert_equal DELETE "$(cat "$SCRIPT_METHOD_FILE")" "ado-rest DELETE method"
unset ADO_TEST_CURL_MODE

script_output="$(PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$PR_COMMENTS" 123 2>&1)"
script_status=$?
[ "$script_status" -eq 0 ] || fail "pr-comments failed with valid Azure context: $script_output"
expected_basic="Authorization: Basic $(printf ':%s' "$AZURE_DEVOPS_PAT_WORK" | "$REAL_BASE64" 2>/dev/null | "$REAL_TR" -d '\r\n')"
assert_equal "$expected_basic" "$(cat "$SCRIPT_HEADER_FILE")" "pr-comments shared PAT header"
[ ! -e "$ADO_TEST_AZ_CALLED_FILE" ] || fail "pr-comments used az despite PAT precedence"
assert_no_secret "$script_output" "$AZURE_DEVOPS_PAT_WORK"
"$REAL_GREP" -Fq 'https://dev.azure.com/script-org/script-project/' "$SCRIPT_URLS_FILE" || fail "pr-comments did not use the parsed Azure org/project context"
assert_equal '@/dev/fd/3' "$(cat "$SCRIPT_AUTH_ARG_FILE")" "curl auth descriptor"
assert_no_secret "$(cat "$SCRIPT_AUTH_ARG_FILE")" "$AZURE_DEVOPS_PAT_WORK"
if find "$TEST_ROOT" -maxdepth 1 -name 'dotfiles-http.*' | "$REAL_GREP" -q .; then fail "curl auth transport created a header file"; fi

# Selecting another organization's profile is rejected before making a request.
"$REAL_GIT" config --local azure-devops.profile personal
rm -f "$SCRIPT_URLS_FILE"
script_output="$(PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$PR_COMMENTS" 123 2>&1)"
[ "$?" -ne 0 ] || fail "pr-comments accepted a profile configured for another organization"
case "$script_output" in *"different organization"*) ;; *) fail "profile mismatch error was not reported" ;; esac
[ ! -s "$SCRIPT_URLS_FILE" ] || fail "profile mismatch sent an HTTP request"
"$REAL_GIT" config --local azure-devops.profile work

# Hyphen/underscore profile collisions must not send the work PAT to a personal org.
COLLISION_WORK_REPO="$(make_repo collision-work https://dev.azure.com/collision-work-org/project/_git/repo)"
COLLISION_PERSONAL_REPO="$(make_repo collision-personal https://dev.azure.com/collision-personal-org/project/_git/repo)"
for collision_repo in "$COLLISION_WORK_REPO" "$COLLISION_PERSONAL_REPO"; do
  "$REAL_GIT" -C "$collision_repo" config azure-devops.work-prod.organization collision-work-org
  "$REAL_GIT" -C "$collision_repo" config azure-devops.work-prod.auth pat
  "$REAL_GIT" -C "$collision_repo" config azure-devops.work_prod.organization collision-personal-org
  "$REAL_GIT" -C "$collision_repo" config azure-devops.work_prod.auth pat
done
"$REAL_GIT" -C "$COLLISION_WORK_REPO" config azure-devops.profile work-prod
"$REAL_GIT" -C "$COLLISION_PERSONAL_REPO" config azure-devops.profile work_prod
export AZURE_DEVOPS_PAT_WORK_PROD=synthetic-collision-work-pat
rm -f "$SCRIPT_HEADER_FILE" "$SCRIPT_URLS_FILE" "$ADO_TEST_AZ_CALLED_FILE"
script_output="$(cd "$COLLISION_WORK_REPO" && PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$FIXTURE_DOTFILES/scripts/ado-rest" GET '/_apis/test' 2>&1)" || fail "hyphenated work profile failed"
collision_basic="Authorization: Basic $(printf ':%s' "$AZURE_DEVOPS_PAT_WORK_PROD" | "$REAL_BASE64" | "$REAL_TR" -d '\r\n')"
assert_equal "$collision_basic" "$(cat "$SCRIPT_HEADER_FILE")" "hyphenated work profile PAT"
"$REAL_GREP" -Fq 'https://dev.azure.com/collision-work-org/' "$SCRIPT_URLS_FILE" || fail "hyphenated profile targeted the wrong org"
assert_no_secret "$script_output" "$AZURE_DEVOPS_PAT_WORK_PROD"
assert_no_secret "$script_output" "${collision_basic#Authorization: Basic }"
rm -f "$SCRIPT_HEADER_FILE" "$SCRIPT_URLS_FILE"
script_output="$(cd "$COLLISION_PERSONAL_REPO" && PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$FIXTURE_DOTFILES/scripts/ado-rest" GET '/_apis/test' 2>&1)"
[ "$?" -ne 0 ] || fail "underscore profile reused the work PAT for the personal org"
case "$script_output" in *'Underscores are not allowed'*) ;; *) fail "colliding profile error was not actionable" ;; esac
[ ! -s "$SCRIPT_URLS_FILE" ] && [ ! -e "$SCRIPT_HEADER_FILE" ] || fail "colliding profile sent an HTTP request"
[ ! -e "$ADO_TEST_AZ_CALLED_FILE" ] || fail "colliding profile fell back to Azure CLI"
assert_no_secret "$script_output" "$AZURE_DEVOPS_PAT_WORK_PROD"
assert_no_secret "$script_output" "${collision_basic#Authorization: Basic }"
unset AZURE_DEVOPS_PAT_WORK_PROD

rm -f "$SCRIPT_HEADER_FILE" "$SCRIPT_URLS_FILE" "$ADO_TEST_AZ_CALLED_FILE"
script_output="$(PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$PR_STATUS" 123 2>&1)"
script_status=$?
[ "$script_status" -eq 0 ] || fail "pr-status failed with valid Azure context: $script_output"
assert_equal "$expected_basic" "$(cat "$SCRIPT_HEADER_FILE")" "pr-status shared profile PAT header"
assert_no_secret "$script_output" "$AZURE_DEVOPS_PAT_WORK"
"$REAL_GREP" -Fq 'https://dev.azure.com/script-org/script-project/' "$SCRIPT_URLS_FILE" || fail "pr-status did not use parsed Azure org/project context"

script_output="$(PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" ADO_TEST_CURL_MODE=failed-build "$PR_STATUS" 123 2>&1)"
[ "$?" -eq 0 ] || fail "failed build details could not be displayed: $script_output"
case "$script_output" in *'ordinary build output'*) ;; *) fail "plain-text build log was not displayed" ;; esac

# API failures must produce non-zero status, without exposing bodies or credentials.
for mode in transport-failure denied invalid-json invalid-policies; do
  script_output="$(PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" ADO_TEST_CURL_MODE="$mode" "$PR_STATUS" 123 2>&1)"
  script_status=$?
  [ "$script_status" -ne 0 ] || fail "pr-status accepted $mode"
  assert_no_secret "$script_output" error-body-secret
  assert_no_secret "$script_output" invalid-json-secret
  assert_no_secret "$script_output" "$AZURE_DEVOPS_PAT_WORK"
done

for interval in '' 0 -1 invalid; do
  if "$PR_STATUS" --interval "$interval" > "$TEST_ROOT/invalid-interval-output" 2>&1; then
    fail "pr-status accepted invalid interval '$interval'"
  fi
done
if "$PR_STATUS" --interval > "$TEST_ROOT/missing-interval-output" 2>&1; then
  fail "pr-status accepted a missing interval"
fi

# Organization listing outside a repository uses the legacy matching organization/PAT pair.
script_output="$(cd "$TEST_ROOT/no-git" && PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" AZURE_DEVOPS_ORG=test-org AZURE_DEVOPS_PAT=synthetic-legacy-pat "$FIXTURE_DOTFILES/scripts/pr" 2>&1)"
[ "$?" -eq 0 ] || fail "pr failed with the shared helpers: $script_output"
"$REAL_GREP" -Fq 'Project%20With%20Spaces/_apis/git/pullrequests' "$SCRIPT_URLS_FILE" || fail "pr did not encode project names"

# Browser lookup shares Azure auth, strips .git, and retains HTTP-error fallback.
cat > "$SCRIPT_BIN/open" <<'EOF'
#!/bin/bash
printf '%s\n' "$3" > "$ADO_TEST_OPEN_FILE"
EOF
chmod +x "$SCRIPT_BIN/open" || fail "could not create browser shim"
export ADO_TEST_OPEN_FILE="$TEST_ROOT/opened-url"
"$REAL_GIT" remote set-url origin git@ssh.dev.azure.com:v3/script-org/script-project/script-repo.git || fail "could not prepare repo lookup"
PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" ADO_TEST_CURL_MODE=repo-pr AZURE_DEVOPS_PAT=repo-pat \
  "$FIXTURE_DOTFILES/scripts/repo" > "$TEST_ROOT/repo-output" 2>&1 || fail "Azure repo lookup failed"
assert_equal 'https://dev.azure.com/script-org/script-project/_git/script-repo/pullrequest/123' "$(cat "$ADO_TEST_OPEN_FILE")" "Azure PR browser URL"
PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" ADO_TEST_CURL_MODE=denied AZURE_DEVOPS_PAT=repo-pat \
  "$FIXTURE_DOTFILES/scripts/repo" > "$TEST_ROOT/repo-error-output" 2>&1 || fail "repo HTTP fallback failed"
assert_equal 'https://dev.azure.com/script-org/script-project/_git/script-repo' "$(cat "$ADO_TEST_OPEN_FILE")" "repository fallback URL"
"$REAL_GIT" remote set-url origin git@github.com:example/sample.git || fail "could not prepare GitHub remote"
PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" GITHUB_TOKEN=github-pat \
  "$FIXTURE_DOTFILES/scripts/repo" > "$TEST_ROOT/github-output" 2>&1 || fail "GitHub repo lookup failed"
assert_equal 'https://github.com/example/sample/pull/42' "$(cat "$ADO_TEST_OPEN_FILE")" "GitHub PR browser URL"

# Publish only into shims: no real push, PR creation, or ClickUp writes are made.
"$REAL_GIT" remote set-url origin git@ssh.dev.azure.com:v3/script-org/script-project/script-repo.git
"$REAL_GIT" -c user.name=Regression -c user.email=regression@example.invalid -c core.hooksPath=/dev/null \
  commit --allow-empty -qm fixture || fail "could not create publish fixture"
"$REAL_GIT" branch -m 'feature/#123-quote"test' || fail "could not create quoted feature branch"
"$REAL_GIT" update-ref refs/remotes/origin/main HEAD
"$REAL_GIT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
PUBLISH_BIN="$TEST_ROOT/publish-bin"
mkdir -p "$PUBLISH_BIN"
cat > "$PUBLISH_BIN/git" <<'EOF'
#!/bin/bash
if [ "${1:-}" = push ]; then
  : > "$ADO_TEST_PUSH_FILE"
  exit 0
fi
exec "$ADO_TEST_REAL_GIT" "$@"
EOF
chmod +x "$PUBLISH_BIN/git"
export ADO_TEST_CURL_BODY_FILE="$TEST_ROOT/posted-body"
printf '\nLiteral \\n stays literal\nn\n' | \
  PATH="$AZ_BIN:$PUBLISH_BIN:$SCRIPT_BIN:$BASE_BIN" \
  AZURE_DEVOPS_PAT=publish-pat CLICKUP_API_TOKEN='' \
  ADO_TEST_REAL_GIT="$REAL_GIT" ADO_TEST_PUSH_FILE="$TEST_ROOT/push-marker" \
  "$FIXTURE_DOTFILES/scripts/submit-pr" 123 > "$TEST_ROOT/submit-output" 2>&1 || fail "submit-pr failed with shims: $(cat "$TEST_ROOT/submit-output")"
[ -e "$TEST_ROOT/push-marker" ] || fail "submit-pr did not use the push shim"
"$REAL_JQ" -e --arg source 'refs/heads/feature/#123-quote"test' \
  --arg description $'Literal \\n stays literal\n\ncloses https://www.clickup.com/t/123' \
  '.sourceRefName == $source and .targetRefName == "refs/heads/main" and .description == $description' \
  "$ADO_TEST_CURL_BODY_FILE" >/dev/null || fail "submit-pr did not preserve JSON strings and newlines"

# ── On-demand alias/.env loading ─────────────────────────────────────
# The interactive shell no longer exports tokens; scripts load them from alias/.env.
# Nothing below may be satisfied by the caller's own environment.
unset AZURE_DEVOPS_PAT AZURE_DEVOPS_PAT_WORK AZURE_DEVOPS_PAT_PERSONAL AZURE_DEVOPS_ORG CLICKUP_API_TOKEN GITHUB_TOKEN LOCAL_ENV_OTHER
export ADO_TEST_AZ_MODE=token
export ADO_TEST_AZ_TOKEN='dotenv-az-token-must-not-print'
DOTENV_PAT='dotenv-pat-with space and $(touch dotenv-injected)'
INJECTION_MARKER="$TEST_ROOT/dotenv-injected"

write_fixture_env() {
  printf '%s\n' "$@" > "$FIXTURE_ENV"
}

write_fixture_env \
  '# per-machine settings' \
  "export AZURE_DEVOPS_PAT='$DOTENV_PAT'" \
  'export AZURE_DEVOPS_ORG=dotenv-org' \
  'export CLICKUP_API_TOKEN="pk_dotenv_clickup"' \
  'export LOCAL_ENV_OTHER=must-not-leak'

# Helper: fills only what is unset or empty, never exports, never leaks other names.
helper_output="$(cd "$TEST_ROOT" && env -u AZURE_DEVOPS_PAT -u CLICKUP_API_TOKEN AZURE_DEVOPS_ORG= \
  /bin/bash -c '
    set -euo pipefail
    source "$1/lib/local-env.sh"
    local_env_load AZURE_DEVOPS_PAT AZURE_DEVOPS_ORG CLICKUP_API_TOKEN GITHUB_TOKEN
    printf "pat=%s\n" "$AZURE_DEVOPS_PAT"
    printf "org=%s\n" "$AZURE_DEVOPS_ORG"
    printf "clickup=%s\n" "$CLICKUP_API_TOKEN"
    printf "github=[%s]\n" "${GITHUB_TOKEN:-}"
    printf "other=[%s]\n" "${LOCAL_ENV_OTHER:-}"
    printf "exported=[%s]\n" "$(env | cut -d= -f1 | grep -xcE "CLICKUP_API_TOKEN|AZURE_DEVOPS_ORG|AZURE_DEVOPS_PAT" || true)"
  ' helper "$FIXTURE_DOTFILES")" || fail "local_env_load failed: $helper_output"
case "$helper_output" in *"pat=$DOTENV_PAT"$'\n'*) ;; *) fail "helper did not load the PAT from alias/.env" ;; esac
case "$helper_output" in *$'org=dotenv-org\n'*) ;; *) fail "helper did not fill an empty value from alias/.env" ;; esac
case "$helper_output" in *$'clickup=pk_dotenv_clickup\n'*) ;; *) fail "helper did not load the ClickUp token" ;; esac
case "$helper_output" in *'github=[]'*) ;; *) fail "helper invented a value for a name alias/.env lacks" ;; esac
case "$helper_output" in *'other=[]'*) ;; *) fail "helper leaked an unrequested alias/.env variable" ;; esac
case "$helper_output" in *'exported=[0]'*) ;; *) fail "helper exported a loaded token to child processes" ;; esac
[ ! -e "$INJECTION_MARKER" ] && [ ! -e "$TEST_ROOT/dotenv-injected" ] || fail "alias/.env value was executed as code"

# Regression: a variable the caller exported as empty must not stay exported once it receives
# the file's value, while a non-empty exported override is kept exactly as it was.
assert_equal 0 "$(cd "$TEST_ROOT" && env -u AZURE_DEVOPS_PAT -u CLICKUP_API_TOKEN CLICKUP_API_TOKEN= \
  /bin/bash -c 'source "$1/lib/local-env.sh"; local_env_load CLICKUP_API_TOKEN
    [ "$CLICKUP_API_TOKEN" = pk_dotenv_clickup ] || exit 7
    env | cut -d= -f1 | grep -xc CLICKUP_API_TOKEN || true' helper "$FIXTURE_DOTFILES")" \
  "empty exported variable stayed exported after loading from alias/.env"
assert_equal 1 "$(cd "$TEST_ROOT" && env -u AZURE_DEVOPS_PAT CLICKUP_API_TOKEN=caller-token \
  /bin/bash -c 'source "$1/lib/local-env.sh"; local_env_load CLICKUP_API_TOKEN
    [ "$CLICKUP_API_TOKEN" = caller-token ] || exit 7
    env | cut -d= -f1 | grep -xc CLICKUP_API_TOKEN || true' helper "$FIXTURE_DOTFILES")" \
  "caller-exported override was altered"
assert_equal 0 "$(cd "$TEST_ROOT" && env -u AZURE_DEVOPS_PAT -u CLICKUP_API_TOKEN CLICKUP_API_TOKEN= \
  zsh -c 'source "$1/lib/local-env.sh"; local_env_load CLICKUP_API_TOKEN
    [ "$CLICKUP_API_TOKEN" = pk_dotenv_clickup ] || exit 7
    env | cut -d= -f1 | grep -xc CLICKUP_API_TOKEN || true' helper "$FIXTURE_DOTFILES")" \
  "empty exported variable stayed exported under zsh"

assert_equal caller-pat "$(AZURE_DEVOPS_PAT=caller-pat /bin/bash -c '
  source "$1/lib/local-env.sh"; local_env_load AZURE_DEVOPS_PAT; printf %s "$AZURE_DEVOPS_PAT"' helper "$FIXTURE_DOTFILES")" \
  "caller value must win over alias/.env"
if /bin/bash -c 'source "$1/lib/local-env.sh"; local_env_load "BAD NAME"' helper "$FIXTURE_DOTFILES" 2>/dev/null; then
  fail "helper accepted an invalid variable name"
fi
mkdir -p "$TEST_ROOT/bare-dotfiles/lib" || fail "could not create bare dotfiles fixture"
cp "$REPO_ROOT/lib/local-env.sh" "$TEST_ROOT/bare-dotfiles/lib/" || fail "could not copy helper"
assert_equal '' "$(/bin/bash -c 'set -euo pipefail; source "$1/lib/local-env.sh"; local_env_load AZURE_DEVOPS_PAT; printf %s "${AZURE_DEVOPS_PAT:-}"' helper "$TEST_ROOT/bare-dotfiles")" \
  "missing alias/.env must be a no-op"

# An alias/.env with failing commands must not abort a set -e script or hide earlier values.
write_fixture_env 'export CLICKUP_API_TOKEN=survives' 'false' 'ls /nonexistent-dotenv-path'
assert_equal survives "$(/bin/bash -c 'set -euo pipefail; source "$1/lib/local-env.sh"; local_env_load CLICKUP_API_TOKEN; printf %s "$CLICKUP_API_TOKEN"' helper "$FIXTURE_DOTFILES")" \
  "failing alias/.env lines"

# local-env is sourced, sets unexported variables in Bash and Zsh, and never prints a value.
write_fixture_env "export AZURE_DEVOPS_PAT='$DOTENV_PAT'" 'export OTHER_NAME=unrequested'
for shell_name in bash zsh; do
  shell_output="$(cd "$TEST_ROOT" && env -u AZURE_DEVOPS_PAT "$shell_name" -c '
    source "$1/scripts/local-env" AZURE_DEVOPS_PAT GITHUB_TOKEN
    load_rc=$?
    printf "status=%s\n" "$load_rc" >&2
    printf "%s" "$AZURE_DEVOPS_PAT" > "$2"
    printf "other=[%s]\n" "${OTHER_NAME:-}" >&2
    printf "exported=[%s]\n" "$(env | cut -d= -f1 | grep -xc AZURE_DEVOPS_PAT || true)" >&2
  ' local-env "$FIXTURE_DOTFILES" "$TEST_ROOT/local-env-value" 2>&1)" || fail "sourcing local-env failed under $shell_name: $shell_output"
  assert_equal "$DOTENV_PAT" "$(cat "$TEST_ROOT/local-env-value")" "local-env round trip under $shell_name"
  case "$shell_output" in *'status=0'*) ;; *) fail "local-env returned an error under $shell_name" ;; esac
  case "$shell_output" in *'other=[]'*) ;; *) fail "local-env set an unrequested name under $shell_name" ;; esac
  case "$shell_output" in *'exported=[0]'*) ;; *) fail "local-env exported the token under $shell_name" ;; esac
  assert_no_secret "$shell_output" "$DOTENV_PAT"
  assert_no_secret "$shell_output" synthetic
done
[ ! -e "$TEST_ROOT/dotenv-injected" ] || fail "local-env executed a value"

# Executing local-env, with or without names, explains itself and never prints a value.
for invocation in "" "AZURE_DEVOPS_PAT"; do
  # shellcheck disable=SC2086 # the optional name list is intentionally word-split
  exec_output="$("$FIXTURE_DOTFILES/scripts/local-env" $invocation 2>&1)" && fail "executing local-env succeeded"
  assert_no_secret "$exec_output" "$DOTENV_PAT"
  case "$exec_output" in *'must be sourced'*) ;; *) fail "executing local-env did not explain how to use it" ;; esac
done
if bash -c 'source "$1/scripts/local-env"' x "$FIXTURE_DOTFILES" > /dev/null 2>&1; then fail "local-env accepted no names"; fi
if bash -c 'source "$1/scripts/local-env" "bad;name"' x "$FIXTURE_DOTFILES" > /dev/null 2>&1; then fail "local-env accepted an invalid name"; fi

# Scripts authenticate with the organization-specific PAT from alias/.env.
write_fixture_env \
  "export AZURE_DEVOPS_PAT_WORK='$DOTENV_PAT'" \
  'export CLICKUP_API_TOKEN="pk_dotenv_clickup"'
cd "$SCRIPT_REPO" || fail "could not enter consumer repository"
"$REAL_GIT" config --local azure-devops.profile work
rm -f "$SCRIPT_HEADER_FILE" "$SCRIPT_AUTH_ARG_FILE" "$SCRIPT_URLS_FILE" "$ADO_TEST_AZ_CALLED_FILE"
script_output="$(PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$PR_COMMENTS" 123 2>&1)" || fail "pr-comments failed using alias/.env: $script_output"
expected_basic="Authorization: Basic $(printf ':%s' "$DOTENV_PAT" | "$REAL_BASE64" 2>/dev/null | "$REAL_TR" -d '\r\n')"
assert_equal "$expected_basic" "$(cat "$SCRIPT_HEADER_FILE")" "pr-comments PAT loaded from alias/.env"
[ ! -e "$ADO_TEST_AZ_CALLED_FILE" ] || fail "pr-comments used az although alias/.env supplies a PAT"
assert_no_secret "$script_output" "$DOTENV_PAT"
"$REAL_GREP" -Fq 'https://dev.azure.com/script-org/script-project/' "$SCRIPT_URLS_FILE" || fail "pr-comments did not bind alias/.env PAT to the remote organization"

# A caller-exported PAT takes precedence over the file.
rm -f "$SCRIPT_HEADER_FILE" "$SCRIPT_URLS_FILE"
PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" AZURE_DEVOPS_PAT_WORK=caller-pat "$PR_STATUS" 123 > /dev/null 2>&1 || fail "pr-status failed with a caller PAT"
expected_basic="Authorization: Basic $(printf ':%s' caller-pat | "$REAL_BASE64" 2>/dev/null | "$REAL_TR" -d '\r\n')"
assert_equal "$expected_basic" "$(cat "$SCRIPT_HEADER_FILE")" "caller PAT precedence over alias/.env"

# A pinned Azure CLI profile works when the selected account and token claims match.
"$REAL_GIT" config --local azure-devops.profile work-cli
"$REAL_GIT" config --local azure-devops.work-cli.organization script-org
"$REAL_GIT" config --local azure-devops.work-cli.auth azure-cli
"$REAL_GIT" config --local azure-devops.work-cli.tenant 11111111-1111-4111-8111-111111111111
"$REAL_GIT" config --local azure-devops.work-cli.user user@example.invalid
"$REAL_GIT" config --local azure-devops.work-cli.object-id 22222222-2222-4222-8222-222222222222
write_fixture_env 'export CLICKUP_API_TOKEN="pk_dotenv_clickup"'
payload=$(jq -cn --arg tid 11111111-1111-4111-8111-111111111111 --arg oid 22222222-2222-4222-8222-222222222222 '{tid:$tid,oid:$oid}')
payload_encoded=$(printf '%s' "$payload" | "$REAL_BASE64" | "$REAL_TR" '+/' '-_' | "$REAL_TR" -d '\r\n=')
export ADO_TEST_AZ_MODE=token
export ADO_TEST_AZ_TENANT=11111111-1111-4111-8111-111111111111 ADO_TEST_AZ_USER=user@example.invalid
export ADO_TEST_AZ_TOKEN="header.${payload_encoded}.signature"
rm -f "$SCRIPT_HEADER_FILE" "$SCRIPT_URLS_FILE" "$ADO_TEST_AZ_CALLED_FILE"
PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$PR_STATUS" 123 > "$TEST_ROOT/cli-profile-output" 2>&1 || fail "pr-status failed using a pinned Azure CLI profile: $(cat "$TEST_ROOT/cli-profile-output")"
assert_equal "Authorization: Bearer $ADO_TEST_AZ_TOKEN" "$(cat "$SCRIPT_HEADER_FILE")" "az fallback header"
[ -e "$ADO_TEST_AZ_CALLED_FILE" ] || fail "Azure CLI profile was not used"
assert_no_secret "$(cat "$TEST_ROOT/cli-profile-output")" "$ADO_TEST_AZ_TOKEN"

# submit-pr reads the ClickUp token from alias/.env.
CLICKUP_HEADER_FILE="$TEST_ROOT/clickup-header"
rm -f "$CLICKUP_HEADER_FILE"
printf '\n\nn\n' | PATH="$AZ_BIN:$PUBLISH_BIN:$SCRIPT_BIN:$BASE_BIN" \
  ADO_TEST_CURL_CLICKUP_HEADER_FILE="$CLICKUP_HEADER_FILE" \
  ADO_TEST_REAL_GIT="$REAL_GIT" ADO_TEST_PUSH_FILE="$TEST_ROOT/push-marker-dotenv" \
  "$FIXTURE_DOTFILES/scripts/submit-pr" 123 > "$TEST_ROOT/submit-dotenv-output" 2>&1
assert_equal 'Authorization: pk_dotenv_clickup' "$(cat "$CLICKUP_HEADER_FILE" 2>/dev/null)" "submit-pr ClickUp token loaded from alias/.env"
assert_no_secret "$(cat "$TEST_ROOT/submit-dotenv-output")" pk_dotenv_clickup

# repo reads GITHUB_TOKEN from alias/.env.
write_fixture_env 'export GITHUB_TOKEN="dotenv-github"'
"$REAL_GIT" remote set-url origin git@github.com:example/sample.git || fail "could not prepare GitHub remote"
rm -f "$ADO_TEST_OPEN_FILE" "$SCRIPT_HEADER_FILE"
PATH="$AZ_BIN:$SCRIPT_BIN:$BASE_BIN" "$FIXTURE_DOTFILES/scripts/repo" > /dev/null 2>&1 || fail "repo failed using GITHUB_TOKEN from alias/.env"
assert_equal 'Authorization: Bearer dotenv-github' "$(cat "$SCRIPT_HEADER_FILE")" "repo GitHub token loaded from alias/.env"
assert_equal 'https://github.com/example/sample/pull/42' "$(cat "$ADO_TEST_OPEN_FILE")" "repo GitHub PR from alias/.env token"

# The interactive shell must not source alias/.env, so new shells carry no token variables.
write_fixture_env 'export CLICKUP_API_TOKEN=leaked-into-shell' 'export AZURE_DEVOPS_PAT=leaked-into-shell'
cp "$REPO_ROOT"/alias/.alias "$REPO_ROOT"/alias/.git_alias "$REPO_ROOT"/alias/.util_alias "$FIXTURE_DOTFILES/alias/"
: > "$FIXTURE_DOTFILES/alias/.user_alias"
shell_environment="$(env -u CLICKUP_API_TOKEN -u AZURE_DEVOPS_PAT zsh -f -c 'source "$1" && env' zsh "$FIXTURE_DOTFILES/alias/.alias")" \
  || fail "alias/.alias could not be sourced by zsh"
case "$shell_environment" in *leaked-into-shell*) fail "alias/.alias exported a token from alias/.env" ;; esac

cd "$PREVIOUS_DIR" || fail "could not restore working directory"
echo "Azure DevOps regression checks passed"
