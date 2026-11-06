#!/bin/bash
# Description: Test top-level PR comments with isolated repositories and mocked HTTP
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pr-comment-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/dotfiles/scripts" "$tmp/dotfiles/lib" "$tmp/dotfiles/alias" "$tmp/bin" "$tmp/repo"
cp "$root/scripts/pr" "$tmp/dotfiles/scripts/"
cp "$root"/lib/*.sh "$tmp/dotfiles/lib/"
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG GIT_CONFIG_COUNT AZURE_DEVOPS_ORG AZURE_DEVOPS_PROFILE AZURE_DEVOPS_PAT AZURE_DEVOPS_PAT_WORK AZURE_DEVOPS_PAT_OTHER
export AZURE_DEVOPS_PAT_WORK=synthetic-work-token AZURE_DEVOPS_PAT_OTHER=synthetic-other-token
export TEST_DIR="$tmp"
cat > "$tmp/bin/curl" <<'MOCK'
#!/bin/bash
set -eu
method='' url='' header='' body=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) case "$2" in @*) header="${2#@}" ;; esac; shift 2 ;;
    --data-binary) body="${2#@}"; shift 2 ;;
    https://*) url="$1"; shift ;;
    --connect-timeout|--max-time|-w) shift 2 ;;
    *) shift ;;
  esac
done
[ "$method" = POST ] && [ "$header" = /dev/fd/3 ] && [ "$body" = /dev/fd/4 ] || exit 5
[ -p "$header" ] && [ -f "$body" ] || exit 6
[ "$(cat "$header")" = "Authorization: Basic $(printf ':synthetic-work-token' | base64 | tr -d '\n')" ] || exit 7
printf '%s\n' "$url" >> "$TEST_DIR/requests"
cat "$body" > "$TEST_DIR/body"
case "${MOCK_MODE:-ok}" in
  ok) printf '{"id":42}\n\n201\n' ;;
  http) printf 'sensitive-response-body\n\n403\n' ;;
  malformed) printf 'sensitive-response-body\n\n201\n' ;;
  missing) printf '{"id":0}\n\n201\n' ;;
  uncertain) exit 28 ;;
esac
MOCK
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
git -C "$tmp/repo" init -q
git -C "$tmp/repo" remote add origin https://dev.azure.com/other/ignored/_git/ignored
git -C "$tmp/repo" remote add selected https://dev.azure.com/example/project/_git/repository
git -C "$tmp/repo" config azure-devops.remote selected
git -C "$tmp/repo" config azure-devops.profile work
git -C "$tmp/repo" config azure-devops.work.organization example
git -C "$tmp/repo" config azure-devops.work.auth pat
cd "$tmp/repo"
pr="$tmp/dotfiles/scripts/pr"
fail() { echo "FAIL: $*" >&2; exit 1; }
reset_requests() { : > "$tmp/requests"; }
no_request() { [ ! -s "$tmp/requests" ] || fail 'unexpected request'; }
check_body() {
  jq -e --rawfile expected "$tmp/input" '.status == 1 and (.comments | length == 1) and .comments[0].parentCommentId == 0 and .comments[0].commentType == 1 and .comments[0].content == $expected' "$tmp/body" >/dev/null || fail 'payload differs'
  [ "$(wc -l < "$tmp/requests" | tr -d ' ')" = 1 ] || fail 'expected one POST'
  [ "$(cat "$tmp/requests")" = 'https://dev.azure.com/example/project/_apis/git/repositories/repository/pullrequests/123/threads?api-version=7.1' ] || fail 'incorrect repository'
}
printf 'literal $HOME `example` \\ quotes "\nUTF-8: 中文\n\n' > "$tmp/input"
reset_requests
[ "$("$pr" comment 123 "$tmp/input")" = 42 ] || fail 'file posting'
check_body
reset_requests
[ "$("$pr" comment 123 - < "$tmp/input")" = 42 ] || fail 'stdin posting'
check_body
awk 'BEGIN { for (i=0;i<30000;i++) print "large literal $value" }' > "$tmp/input"
reset_requests
[ "$("$pr" comment 123 "$tmp/input")" = 42 ] || fail 'large posting'
check_body
for args in '' '0 -' '-1 -' 'abc -' '1' '1 - extra' '1 /missing'; do
  reset_requests
  # Deliberate word splitting exercises the CLI argument count.
  # shellcheck disable=SC2086
  if "$pr" comment $args < /dev/null > "$tmp/out" 2>&1; then fail 'invalid arguments accepted'; fi
  no_request
done
: > "$tmp/input"
reset_requests
if "$pr" comment 1 "$tmp/input" > "$tmp/out" 2>&1; then fail 'empty accepted'; fi
no_request
printf '\377' > "$tmp/input"
if "$pr" comment 1 "$tmp/input" > "$tmp/out" 2>&1; then fail 'invalid UTF-8 accepted'; fi
no_request
printf 'hello\n' > "$tmp/input"
git config azure-devops.work.organization wrong
if "$pr" comment 1 "$tmp/input" > "$tmp/out" 2>&1; then fail 'wrong org accepted'; fi
no_request
git config azure-devops.work.organization example
unset AZURE_DEVOPS_PAT_WORK
if "$pr" comment 1 "$tmp/input" > "$tmp/out" 2>&1; then fail 'missing auth accepted'; fi
no_request
export AZURE_DEVOPS_PAT_WORK=synthetic-work-token
git remote set-url selected https://github.com/example/repository.git
if "$pr" comment 1 "$tmp/input" > "$tmp/out" 2>&1; then fail 'GitHub accepted'; fi
no_request
git remote set-url selected https://dev.azure.com/example/project/_git/repository
for mode in http malformed missing uncertain; do
  reset_requests
  if MOCK_MODE="$mode" "$pr" comment 123 "$tmp/input" > "$tmp/out" 2>&1; then fail "$mode accepted"; fi
  [ "$(wc -l < "$tmp/requests" | tr -d ' ')" = 1 ] || fail "$mode did not send exactly one POST"
  if grep -qi 'sensitive-response-body\|synthetic-work-token\|hello\|parse error\|jq:' "$tmp/out"; then fail 'unsafe output'; fi
  grep -q 'Inspect the PR before retrying' "$tmp/out" || fail 'missing uncertain outcome warning'
done
mkdir "$tmp/signal-tmp"
reset_requests
python3 - "$pr" "$tmp/signal-tmp" <<'PY'
import glob
import os
import signal
import subprocess
import sys
import time

env = os.environ.copy()
env['TMPDIR'] = sys.argv[2]
proc = subprocess.Popen([sys.argv[1], 'comment', '123', '-'], stdin=subprocess.PIPE,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        env=env, start_new_session=True)
try:
    proc.stdin.write(b'synthetic private comment')
    proc.stdin.flush()
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        files = glob.glob(os.path.join(sys.argv[2], 'pr-comment.*', 'text'))
        if files and os.path.getsize(files[0]) > 0:
            break
        time.sleep(0.02)
    else:
        raise RuntimeError('comment input did not reach the private temporary file')
    os.killpg(proc.pid, signal.SIGTERM)
    if proc.wait(timeout=10) != 143:
        raise RuntimeError('SIGTERM did not exit through the signal handler')
    if glob.glob(os.path.join(sys.argv[2], 'pr-comment.*')):
        raise RuntimeError('SIGTERM left private comment files behind')
finally:
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
    proc.stdin.close()
PY
no_request
echo 'pr comment regression: passed'
