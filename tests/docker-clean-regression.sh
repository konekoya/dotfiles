#!/bin/bash
# Description: Regression coverage for Docker cleanup confirmation and failures

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/docker-clean-regression.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/home/dotfiles/scripts" "$TEST_ROOT/bin"
cp "$REPO_ROOT/scripts/docker-clean" "$TEST_ROOT/home/dotfiles/scripts/docker-clean"
DOCKER_CLEAN="$TEST_ROOT/home/dotfiles/scripts/docker-clean"
export HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/bin:$PATH"
export DOCKER_TEST_LOG="$TEST_ROOT/calls" DOCKER_TEST_MODE=normal

cat > "$TEST_ROOT/bin/docker" <<'EOF'
#!/bin/bash
printf '<%s>' "$@" >> "$DOCKER_TEST_LOG"
printf '\n' >> "$DOCKER_TEST_LOG"
case "$1" in
  ps)
    [ "$DOCKER_TEST_MODE" != list-failure ] || exit 1
    [ "$DOCKER_TEST_MODE" != empty ] || exit 0
    # A running app and a stopped database, both with status text containing spaces.
    printf 'aaa111\tapp\tUp 2 hours\nbbb222\tdatabase\tExited (0) 1 hour ago\n'
    ;;
  stop) [ "$DOCKER_TEST_MODE" != stop-failure ] ;;
  rm) [ "$DOCKER_TEST_MODE" != remove-failure ] ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/docker"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_clean() {
  local input="$1"
  shift
  : > "$DOCKER_TEST_LOG"
  status=0
  printf '%s' "$input" | /bin/bash "$DOCKER_CLEAN" "$@" > "$TEST_ROOT/output" 2>&1 || status=$?
}

assert_no_changes() {
  if grep -Eq '^<(stop|rm)>' "$DOCKER_TEST_LOG"; then
    fail "cleanup changed containers without confirmation"
  fi
}

assert_removed_snapshot() {
  [ "$(wc -l < "$DOCKER_TEST_LOG" | tr -d ' ')" = 3 ] || fail "expected one listing, one stop, and one removal"
  tail -n 2 "$DOCKER_TEST_LOG" > "$TEST_ROOT/mutations"
  printf '<stop><aaa111><bbb222>\n<rm><aaa111><bbb222>\n' > "$TEST_ROOT/expected"
  cmp -s "$TEST_ROOT/expected" "$TEST_ROOT/mutations" || fail "cleanup did not stop and remove exactly the previewed IDs"
  grep -Fq 'Done.' "$TEST_ROOT/output" || fail "successful cleanup did not report completion"
}

for answer in '' $'\n' $'n\n' $'no\n' $'maybe\n'; do
  run_clean "$answer"
  [ "$status" = 0 ] || fail "cancellation failed"
  assert_no_changes
  grep -Fq 'Cancelled.' "$TEST_ROOT/output" || fail "cancellation was not reported"
done

for answer in $'y\n' $'Y\n' $'yes\n' $'YeS\n'; do
  run_clean "$answer"
  [ "$status" = 0 ] || fail "confirmation failed"
  assert_removed_snapshot
done

for flag in -y --yes; do
  run_clean '' "$flag"
  [ "$status" = 0 ] || fail "$flag required input"
  assert_removed_snapshot
  if grep -Fq '[y/N]' "$TEST_ROOT/output"; then
    fail "$flag did not skip the prompt"
  fi
done

DOCKER_TEST_MODE=empty
run_clean ''
[ "$status" = 0 ] || fail "empty daemon failed"
assert_no_changes
grep -Fq 'No containers to remove.' "$TEST_ROOT/output" || fail "empty daemon was not reported"

for mode in list-failure stop-failure remove-failure; do
  DOCKER_TEST_MODE="$mode"
  run_clean '' --yes
  [ "$status" != 0 ] || fail "$mode returned success"
  if grep -Fq 'Done.' "$TEST_ROOT/output"; then
    fail "$mode reported completion"
  fi
  if [ "$mode" = list-failure ]; then
    assert_no_changes
  elif [ "$mode" = stop-failure ] && grep -Fq '<rm>' "$DOCKER_TEST_LOG"; then
    fail "cleanup removed containers after stopping failed"
  fi
done

DOCKER_TEST_MODE=normal
run_clean '' --unknown
[ "$status" = 2 ] || fail "unknown option was accepted"
[ ! -s "$DOCKER_TEST_LOG" ] || fail "unknown option called Docker"
run_clean '' --help
[ "$status" = 0 ] || fail "help failed"
[ ! -s "$DOCKER_TEST_LOG" ] || fail "help called Docker"

# Hold stdin open and verify the complete preview appears before any mutation.
python3 - "$DOCKER_CLEAN" "$DOCKER_TEST_LOG" <<'PY'
import os
from pathlib import Path
import select
import subprocess
import sys
import time

script, log = sys.argv[1:]
Path(log).write_text('')
process = subprocess.Popen(['/bin/bash', script], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
output = b''
try:
    deadline = time.monotonic() + 10
    while b'[y/N]' not in output:
        assert time.monotonic() < deadline, 'confirmation prompt did not appear'
        if select.select([process.stdout], [], [], 0.1)[0]:
            chunk = os.read(process.stdout.fileno(), 65536)
            assert chunk, 'cleanup exited before confirmation'
            output += chunk
    assert b'aaa111\tapp\tUp 2 hours' in output, 'running container missing from preview'
    assert b'bbb222\tdatabase\tExited (0) 1 hour ago' in output, 'stopped container missing from preview'
    assert len(Path(log).read_text().splitlines()) == 1, 'cleanup mutated containers before confirmation'
    assert process.poll() is None, 'cleanup did not wait for confirmation'
    process.communicate(b'y\n', timeout=10)
    assert process.returncode == 0, 'confirmed cleanup failed'
    assert Path(log).read_text().splitlines()[1:] == ['<stop><aaa111><bbb222>', '<rm><aaa111><bbb222>']
finally:
    if process.poll() is None:
        process.kill()
        process.communicate()
PY

echo "docker-clean regression checks passed"
