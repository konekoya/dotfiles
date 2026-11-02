#!/bin/bash
# Description: Regression coverage for gh-auth token scoping and auth classification

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gh-auth-regression.XXXXXX")" || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equal() {
  [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

# Fixture copy of the script and loader, so the real alias/.env is never involved.
DOTFILES="$TEST_ROOT/dotfiles"
mkdir -p "$DOTFILES/scripts" "$DOTFILES/lib" "$DOTFILES/alias" "$TEST_ROOT/bin" "$TEST_ROOT/nogh" || fail "could not create fixture"
cp "$REPO_ROOT/scripts/gh-auth" "$DOTFILES/scripts/" || fail "could not copy gh-auth"
cp "$REPO_ROOT/lib/local-env.sh" "$DOTFILES/lib/" || fail "could not copy loader"
GH_AUTH="$DOTFILES/scripts/gh-auth"
ENV_FILE="$DOTFILES/alias/.env"

# The mock records only whether the token it received equals the expected synthetic value, so
# no token value is ever written to a file or printed. GH_TEST_STATUS_MODE drives `auth status`.
cat > "$TEST_ROOT/bin/gh" <<'MOCK'
#!/bin/bash
{
  if [ "${GH_TOKEN-unset}" = unset ]; then echo "token=absent"
  elif [ "$GH_TOKEN" = "${GH_TEST_EXPECT:-}" ]; then echo "token=expected"
  else echo "token=other"; fi
  echo "argc=$#"
  if [[ " $* " == *synthetic-* ]]; then echo "argv_has_token=yes"; else echo "argv_has_token=no"; fi
} > "$GH_TEST_RECORD"
if [ "$1 $2" = "auth status" ]; then
  case "${GH_TEST_STATUS_MODE:-ok}" in
    ok) exit 0 ;;
    missing) echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2; exit 1 ;;
    invalid) echo "X Failed to log in to github.com account (GH_TOKEN): The token in GH_TOKEN is invalid." >&2; exit 1 ;;
    sandbox) echo "error connecting to api.github.com: dial tcp: lookup api.github.com: no such host" >&2; exit 1 ;;
    codex-dns) echo "X Failed to log in to github.com account (GH_TOKEN): failed to make HTTP request: Get https://api.github.com/: dial tcp: lookup api.github.com: no such host" >&2; exit 1 ;;
    curl-dns) echo "curl: (6) Could not resolve host: api.github.com" >&2; exit 1 ;;
    tls) echo "Get https://api.github.com/: x509: certificate signed by unknown authority" >&2; exit 1 ;;
    network) echo "Failed to connect to api.github.com port 443: Could not connect to server" >&2; exit 1 ;;
    ambiguous-login) echo "X Failed to log in to github.com account (GH_TOKEN)" >&2; exit 1 ;;
    denied) echo "open /Users/x/.config/gh/hosts.yml: operation not permitted" >&2; exit 1 ;;
    other) echo "something unexpected" >&2; exit 1 ;;
  esac
fi
exit 0
MOCK
chmod +x "$TEST_ROOT/bin/gh" || fail "could not create gh mock"
export GH_TEST_RECORD="$TEST_ROOT/record"
SAFE_PATH="$TEST_ROOT/bin:/usr/bin:/bin"

run() { # run <extra env assignments...> -- <args...>
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env -u GH_TOKEN -u GITHUB_TOKEN PATH="$SAFE_PATH" "${envs[@]}" "$GH_AUTH" "$@"
}
record() { grep "^$1=" "$GH_TEST_RECORD" | cut -d= -f2; }

# 1. alias/.env token reaches gh as GH_TOKEN, only in that process and never in argv.
echo 'export GITHUB_TOKEN="synthetic-dotenv-token"' > "$ENV_FILE"
run GH_TEST_EXPECT=synthetic-dotenv-token -- pr list --repo o/r || fail "wrapped gh failed"
assert_equal expected "$(record token)" "alias/.env token passed as GH_TOKEN"
assert_equal no "$(record argv_has_token)" "token kept out of argv"
assert_equal 4 "$(record argc)" "arguments forwarded unchanged"

# 2. The token does not leak into the caller's environment.
leak="$(env -u GH_TOKEN -u GITHUB_TOKEN PATH="$SAFE_PATH" GH_TEST_EXPECT=x /bin/bash -c '"$1" pr list >/dev/null; printf "%s|%s" "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}"' _ "$GH_AUTH")"
assert_equal 'unset|unset' "$leak" "caller environment untouched"

# 3. A caller-provided GH_TOKEN wins over alias/.env; a caller GITHUB_TOKEN wins over the file.
run GH_TOKEN=synthetic-caller GH_TEST_EXPECT=synthetic-caller -- pr list || fail "caller GH_TOKEN run failed"
assert_equal expected "$(record token)" "caller GH_TOKEN wins"
run GITHUB_TOKEN=synthetic-caller-pat GH_TEST_EXPECT=synthetic-caller-pat -- pr list || fail "caller GITHUB_TOKEN run failed"
assert_equal expected "$(record token)" "caller GITHUB_TOKEN wins over alias/.env"

# 4. No configured PAT: gh is run with no token so its own login is the fallback.
rm -f "$ENV_FILE"
run -- pr list || fail "fallback run failed"
assert_equal absent "$(record token)" "no GH_TOKEN without a configured PAT"
echo '# nothing configured' > "$ENV_FILE"
run -- pr list || fail "empty alias/.env run failed"
assert_equal absent "$(record token)" "no GH_TOKEN with an empty alias/.env"

# 5. --check classification, token source, and silence about raw output.
check() { # check <mode> <expected exit> <expected word>
  local out rc=0
  out="$(run GH_TEST_STATUS_MODE="$1" -- --check 2>&1)" || rc=$?
  assert_equal "$2" "$rc" "--check exit for $1"
  case "$out" in *"$3"*) ;; *) fail "--check output for $1 lacks '$3'" ;; esac
  case "$out" in *synthetic*|*unexpected*|*hosts.yml*|*GH_TOKEN*) fail "--check echoed raw gh output for $1" ;; esac
}
check ok 0 'ok (source: gh-login)'
check missing 10 missing
check invalid 11 invalid
check sandbox 12 blocked
check codex-dns 12 blocked
check curl-dns 12 blocked
check tls 12 blocked
check network 12 blocked
check denied 12 blocked
check ambiguous-login 1 unknown
check other 1 unknown

echo 'export GITHUB_TOKEN="synthetic-dotenv-token"' > "$ENV_FILE"
out="$(run GH_TEST_STATUS_MODE=ok GH_TEST_EXPECT=synthetic-dotenv-token -- --check)" || fail "--check with PAT failed"
assert_equal 'gh-auth: ok (source: GITHUB_TOKEN)' "$out" "--check reports the source by name"
assert_equal expected "$(record token)" "--check authenticates with the PAT"
rc=0
run GH_TEST_STATUS_MODE=invalid -- --check >/dev/null || rc=$?
assert_equal 11 "$rc" "invalid PAT is reported, not silently replaced by gh login"

# 6. Usage and a missing gh binary.
rc=0
run -- >/dev/null 2>&1 || rc=$?
assert_equal 2 "$rc" "usage without arguments"
rc=0
env -u GH_TOKEN -u GITHUB_TOKEN PATH="$TEST_ROOT/nogh:/usr/bin:/bin" "$GH_AUTH" --check >/dev/null 2>&1 || rc=$?
assert_equal 13 "$rc" "gh missing"

echo "gh-auth regression checks passed"
