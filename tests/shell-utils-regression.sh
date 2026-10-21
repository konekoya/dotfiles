#!/bin/bash
# Description: Regression coverage for alias loading, bookmark quoting, and menu terminal cleanup

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/shell-utils-regression.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME/dotfiles/alias" "$TEST_HOME/dotfiles/scripts" "$TEST_ROOT/menu"

# A fresh checkout has no machine-local files and must still load shared aliases quietly.
# Use a path with spaces to exercise quoting without touching the real local files.
ALIAS_DIR="$TEST_ROOT/checkout with spaces/alias"
mkdir -p "$ALIAS_DIR"
cp "$REPO_ROOT/alias/.alias" "$REPO_ROOT/alias/.git_alias" "$REPO_ROOT/alias/.util_alias" "$ALIAS_DIR/"
HOME="$TEST_HOME" zsh -f -c '
  source "$1" || exit 1
  [[ ${aliases[gs]} == "git status" && -n ${aliases[server]} ]]
' zsh "$ALIAS_DIR/.alias" > "$TEST_ROOT/alias-output" 2>&1 \
  || { echo "FAIL: aliases did not load without machine-local files"; exit 1; }
[ ! -s "$TEST_ROOT/alias-output" ] || { echo "FAIL: alias loading printed output for missing local files"; exit 1; }

# Existing local aliases still load after shared aliases; .env is never sourced.
printf 'alias gs="git status --short"\n' > "$ALIAS_DIR/.user_alias"
printf 'exit 99\n' > "$ALIAS_DIR/.env"
HOME="$TEST_HOME" zsh -f -c '
  source "$1" || exit 1
  [[ ${aliases[gs]} == "git status --short" && -n ${aliases[server]} ]]
' zsh "$ALIAS_DIR/.alias" > "$TEST_ROOT/alias-output" 2>&1 \
  || { echo "FAIL: local aliases did not load or .env was sourced"; exit 1; }
[ ! -s "$TEST_ROOT/alias-output" ] || { echo "FAIL: loading existing aliases printed output"; exit 1; }

# Exercise checkout/rebase branch selection without reading the user's Git configuration.
HOME="$TEST_HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 zsh -f -e -c '
  alias grm="git rebase master"
  alias grd="git rebase develop"
  source "$1" || exit 1
  source "$1" || exit 1
  test_root=$2
  export GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.invalid"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  fail() { print -u2 -r -- "FAIL: $*"; exit 1; }

  test_git_alias() {
    local base=$1 checkout_alias=$2 rebase_alias=$3 other=${4-}
    mkdir "$test_root/git-$base"
    cd "$test_root/git-$base"
    git init -q -b "$base"
    git -c core.hooksPath=/dev/null commit -q --allow-empty -m initial
    # The preferred branch must win even when its fallback also exists.
    if [[ -n $other ]]; then git branch "$other"; fi
    git checkout -qb topic
    print feature > feature.txt
    git add feature.txt
    git -c core.hooksPath=/dev/null commit -qm feature
    local original_tip=$(git rev-parse HEAD)
    "$checkout_alias"
    [[ $(git symbolic-ref --short HEAD) == "$base" ]] || fail "$checkout_alias selected the wrong branch"
    print base > base.txt
    git add base.txt
    git -c core.hooksPath=/dev/null commit -qm base
    git checkout -q topic
    "$rebase_alias" --quiet
    [[ $(git symbolic-ref --short HEAD) == topic ]] || fail "$rebase_alias switched branches"
    [[ $(git rev-parse HEAD) != "$original_tip" ]] || fail "$rebase_alias did not rebase"
    git merge-base --is-ancestor "$base" HEAD || fail "$rebase_alias used the wrong base"
    [[ -f base.txt && -f feature.txt ]] || fail "$rebase_alias lost changes"
  }
  test_git_alias master gcm grm main
  test_git_alias main gcm grm
  test_git_alias develop gcd grd dev
  test_git_alias dev gcd grd

  mkdir "$test_root/git-missing"
  cd "$test_root/git-missing"
  git init -q -b topic
  git -c core.hooksPath=/dev/null commit -q --allow-empty -m initial
  original_tip=$(git rev-parse HEAD)
  for shortcut in gcm grm gcd grd; do
    case $shortcut in
      gcm|grm) expected="$shortcut: neither '\''master'\'' nor '\''main'\'' branch found" ;;
      gcd|grd) expected="$shortcut: neither '\''develop'\'' nor '\''dev'\'' branch found" ;;
    esac
    if "$shortcut" > "$test_root/git-output" 2> "$test_root/git-error"; then
      fail "$shortcut succeeded without a base branch"
    fi
    [[ ! -s "$test_root/git-output" && $(<"$test_root/git-error") == "$expected" ]] \
      || fail "$shortcut did not print the expected error"
    [[ $(git rev-parse HEAD) == "$original_tip" ]] || fail "$shortcut changed HEAD on failure"
  done
' zsh "$ALIAS_DIR/.git_alias" "$TEST_ROOT" > "$TEST_ROOT/git-alias-output" 2>&1 \
  || { cat "$TEST_ROOT/git-alias-output"; echo "FAIL: Git alias regression checks failed"; exit 1; }

# bookmark locates the dotfiles directory from its own path, so run a copy inside the fixture.
cp "$REPO_ROOT/scripts/bookmark" "$TEST_HOME/dotfiles/scripts/bookmark"
BOOKMARK="$TEST_HOME/dotfiles/scripts/bookmark"

# The generated alias must load and run without evaluating characters in the path.
BOOKMARK_DIR="$TEST_ROOT/"$'quotes \' " $HOME $(touch expanded-marker) `touch expanded-marker` \\ and\nnewline'
mkdir -p "$BOOKMARK_DIR"
cd "$BOOKMARK_DIR"
printf 'special\n' | HOME="$TEST_HOME" "$BOOKMARK" > "$TEST_ROOT/bookmark-output"
cd "$TEST_ROOT"
zsh -f -c 'source "$1"; eval special; [[ "$PWD" -ef "$2" ]]' \
  zsh "$TEST_HOME/dotfiles/alias/.user_alias" "$BOOKMARK_DIR"
[ ! -e "$TEST_ROOT/expanded-marker" ] || { echo "FAIL: bookmark executed path content"; exit 1; }
rm "$TEST_HOME/dotfiles/alias/.user_alias"
ln -s "$TEST_ROOT/missing-alias" "$TEST_HOME/dotfiles/alias/.user_alias"
if printf 'broken\n' | HOME="$TEST_HOME" "$BOOKMARK" > "$TEST_ROOT/broken-output" 2>&1; then
  echo "FAIL: bookmark accepted a broken user alias link"
  exit 1
fi
[ ! -e "$TEST_ROOT/missing-alias" ] || { echo "FAIL: bookmark created a broken link target"; exit 1; }

# bookmark writes next to the repository it runs from, wherever that is.
mkdir -p "$TEST_ROOT/elsewhere/scripts" "$TEST_ROOT/elsewhere/alias"
cp "$REPO_ROOT/scripts/bookmark" "$TEST_ROOT/elsewhere/scripts/bookmark"
printf 'moved\n' | HOME="$TEST_HOME" "$TEST_ROOT/elsewhere/scripts/bookmark" > "$TEST_ROOT/moved-output"
grep -Fq 'alias moved=' "$TEST_ROOT/elsewhere/alias/.user_alias" || { echo "FAIL: bookmark ignored its own location"; exit 1; }

# config-git fills missing identity values from alias/.env; exported values win.
mkdir -p "$TEST_ROOT/identity/scripts" "$TEST_ROOT/identity/lib" "$TEST_ROOT/identity/alias" "$TEST_ROOT/identity-repo"
cp "$REPO_ROOT/scripts/config-git" "$TEST_ROOT/identity/scripts/config-git"
cp "$REPO_ROOT/lib/local-env.sh" "$TEST_ROOT/identity/lib/local-env.sh"
printf 'export GIT_WORK_NAME="File Name"\nexport GIT_WORK_EMAIL="file@example.invalid"\n' > "$TEST_ROOT/identity/alias/.env"
git -C "$TEST_ROOT/identity-repo" init -q
(cd "$TEST_ROOT/identity-repo" && env -u GIT_WORK_NAME -u GIT_WORK_EMAIL HOME="$TEST_HOME" \
  "$TEST_ROOT/identity/scripts/config-git" > "$TEST_ROOT/identity-output")
[ "$(git -C "$TEST_ROOT/identity-repo" config --local user.name)" = "File Name" ] || { echo "FAIL: config-git ignored alias/.env name"; exit 1; }
[ "$(git -C "$TEST_ROOT/identity-repo" config --local user.email)" = "file@example.invalid" ] || { echo "FAIL: config-git ignored alias/.env email"; exit 1; }
(cd "$TEST_ROOT/identity-repo" && env -u GIT_WORK_EMAIL GIT_WORK_NAME="Env Name" HOME="$TEST_HOME" \
  "$TEST_ROOT/identity/scripts/config-git" > "$TEST_ROOT/identity-output")
[ "$(git -C "$TEST_ROOT/identity-repo" config --local user.name)" = "Env Name" ] || { echo "FAIL: config-git let alias/.env override the environment"; exit 1; }
[ "$(git -C "$TEST_ROOT/identity-repo" config --local user.email)" = "file@example.invalid" ] || { echo "FAIL: config-git did not fill the missing email from alias/.env"; exit 1; }

# Exercise the actual Bash menu through a pseudo-terminal, without fzf or live scripts.
cp "$REPO_ROOT/scripts/cmds" "$TEST_ROOT/menu/cmds"
cat > "$TEST_ROOT/menu/a-selected" <<'EOF'
#!/bin/bash
# Description: Record terminal state before running a selected command
"$MENU_PYTHON" -c 'import json, sys, termios; print(json.dumps(termios.tcgetattr(sys.stdin.fileno())[:6]))' > "$MENU_STATE_FILE"
printf 'SELECTED-COMMAND\n'
exit 7
EOF
chmod +x "$TEST_ROOT/menu/a-selected"
python3 - "$TEST_ROOT/menu/cmds" "$TEST_ROOT" "$(command -v bash)" <<'PY'
import os
import json
import pty
import select
import signal
import subprocess
import sys
import time
import termios
from pathlib import Path

menu, root, bash = sys.argv[1:]
def reset_signals():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)

for action, expected_status in [('select', 7), ('cancel', 0), ('interrupt', 130), ('terminate', 143)]:
    master, slave = pty.openpty()
    state_file = Path(root) / (action + '-state')
    original = termios.tcgetattr(slave)
    # macOS may set PENDIN while switching canonical input mode; it is transient.
    original[3] &= ~getattr(termios, 'PENDIN', 0)
    env = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin', TERM='xterm', MENU_STATE_FILE=str(state_file), MENU_PYTHON=sys.executable)
    process = subprocess.Popen([bash, menu], stdin=slave, stdout=slave, stderr=slave, env=env, preexec_fn=reset_signals)
    output = b''
    try:
        deadline = time.monotonic() + 10
        while b'Enter run' not in output:
            if time.monotonic() >= deadline:
                raise AssertionError('menu did not render')
            if select.select([master], [], [], 0.1)[0]:
                output += os.read(master, 65536)
        if action == 'select':
            os.write(master, b'\n')
        elif action == 'cancel':
            os.write(master, b'q')
        else:
            process.send_signal(signal.SIGINT if action == 'interrupt' else signal.SIGTERM)
        while process.poll() is None:
            if time.monotonic() >= deadline:
                raise AssertionError((action, 'menu did not finish'))
            if select.select([master], [], [], 0.1)[0]:
                output += os.read(master, 65536)
        while select.select([master], [], [], 0.1)[0]:
            output += os.read(master, 65536)
        assert process.returncode == expected_status, (action, process.returncode, output)
        restored = termios.tcgetattr(slave)
        restored[3] &= ~getattr(termios, 'PENDIN', 0)
        assert restored == original, (action, 'terminal state was not restored')
        assert b'\x1b[?25h' in output, (action, 'cursor was not restored')
        if action == 'select':
            child_modes = json.loads(state_file.read_text())
            child_modes[3] &= ~getattr(termios, 'PENDIN', 0)
            assert child_modes == original[:6], 'child inherited changed terminal settings'
            assert output.index(b'\x1b[?25h') < output.index(b'SELECTED-COMMAND'), 'cleanup ran too late'
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
PY

echo "shell utility regression checks passed"
