#!/bin/bash
# Description: Regression coverage for check-all output, failures, and CI coverage drift
set -Eeuo pipefail
trap 'echo "FAIL: check-all regression at line $LINENO" >&2' ERR
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/repo with spaces" "$TMP/capture"
export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export TMPDIR="$TMP/capture"
REPO="$TMP/repo with spaces"
mkdir -p "$REPO/scripts" "$REPO/lib" "$REPO/tests" "$REPO/alias" "$REPO/zsh"
cp "$ROOT/scripts/check-all" "$REPO/scripts/"
CLI="$REPO/scripts/check-all"
for file in install.sh lib/fixture.sh alias/.alias alias/.git_alias alias/.util_alias zsh/.zshrc.shared; do
  printf '#!/bin/bash\n:\n' > "$REPO/$file"
done
# Nested check-all runs see only synthetic regressions, so they cannot recurse.
cat > "$REPO/tests/a.sh" <<'FIXTURE'
#!/bin/bash
printf 'fixture stdout\n'
printf 'fixture stderr\n' >&2
# Capture directories/files must be private while a child check is running.
for directory in "$TMPDIR"/check-all.*; do
  [ "$(stat -f %Lp "$directory")" = 700 ] || exit 8
  [ "$(stat -f %Lp "$directory/output")" = 600 ] || exit 9
done
FIXTURE
printf '#!/bin/bash\nprintf sentinel > "$HOME/sentinel"\n' > "$REPO/tests/z.sh"
# This synthetic file fails if configuration is accidentally sourced.
printf 'exit 99\n' > "$REPO/alias/.env"
git -C "$REPO" init -q
git -C "$REPO" add .
# A fixture commit is unnecessary: compare modifications against the initial index.
cd "$TMP"
run_check() {
  if /bin/bash "$CLI" "$@" > "$TMP/output" 2>&1; then result=0; else result=$?; fi
  [ -z "$(/usr/bin/find "$TMP/capture" -mindepth 1 -print)" ]
}
assert_output() { grep -Fq "$1" "$TMP/output" || { echo "FAIL: missing assertion: $1" >&2; exit 1; }; }
run_check
[ "$result" -eq 0 ]
assert_output '0 failed'
! grep -q 'fixture stdout\|fixture stderr' "$TMP/output"
[ -f "$HOME/sentinel" ]
run_check --verbose
[ "$result" -eq 0 ]
assert_output 'fixture stdout'
assert_output 'fixture stderr'

printf 'if then\n' > "$REPO/lib/broken.sh"
printf 'if then\n' > "$REPO/alias/.alias"
printf '#!/bin/bash\necho $unquoted_fixture\n' > "$REPO/scripts/lint-fixture"
printf '#!/bin/bash\n:   \n' > "$REPO/install.sh"
printf '\nexit 7\n' >> "$REPO/tests/a.sh"
rm "$HOME/sentinel"
run_check
[ "$result" -eq 1 ]
assert_output 'FAIL: Bash syntax: lib/broken.sh'
assert_output 'FAIL: Zsh syntax: alias/.alias'
assert_output 'FAIL: Whitespace: unstaged'
assert_output 'FAIL: ShellCheck'
assert_output 'FAIL: Regression: tests/a.sh (exit 7)'
assert_output 'PASS: Regression: tests/z.sh'
assert_output '5 failed'
! grep -q 'fixture stdout\|fixture stderr\|unquoted_fixture' "$TMP/output"
[ -f "$HOME/sentinel" ]
# Stage the whitespace defect and restore a clean working copy of that file.
git -C "$REPO" add install.sh
run_check
[ "$result" -eq 1 ]
assert_output 'PASS: Whitespace: unstaged'
assert_output 'FAIL: Whitespace: staged'
assert_output '5 failed'
run_check --verbose
[ "$result" -eq 1 ]
assert_output 'fixture stdout'
assert_output 'fixture stderr'
assert_output 'SC2154'
run_check --unknown
[ "$result" -eq 2 ]
run_check --verbose extra
[ "$result" -eq 2 ]
run_check --help
[ "$result" -eq 0 ]
assert_output 'Usage: check-all'

# A restricted PATH models absent tools while allowing capture setup/cleanup.
mkdir "$TMP/bin"
for tool in dirname mktemp rm; do ln -s "$(command -v "$tool")" "$TMP/bin/$tool"; done
PATH="$TMP/bin" run_check
[ "$result" -eq 1 ]
assert_output 'missing zsh'
assert_output 'missing git'
assert_output 'missing shellcheck'
assert_output 'Regression: tests/z.sh'

# Mutation fixtures exercise the small drift assertions in the existing CI test.
mkdir -p "$TMP/drift/tests" "$TMP/drift/scripts" "$TMP/drift/.github/workflows"
cp "$ROOT/tests/ci-workflow-regression.sh" "$TMP/drift/tests/"
cp "$ROOT/.github/workflows/checks.yml" "$TMP/drift/.github/workflows/"
cp "$ROOT/scripts/check-all" "$TMP/drift/scripts/"
/bin/bash "$TMP/drift/tests/ci-workflow-regression.sh" > "$TMP/drift-output" 2>&1
for needle in 'install.sh scripts/* lib/*.sh tests/*.sh' \
  'alias/.alias alias/.git_alias alias/.util_alias zsh/.zshrc.shared' \
  'git diff --check' 'shellcheck -S warning -x' 'for file in tests/*.sh' \
  '/bin/bash -n' '/bin/bash "$file"' 'git diff --cached --check'; do
  NEEDLE="$needle" python3 - "$ROOT/scripts/check-all" "$TMP/drift/scripts/check-all" <<'PY'
import os, pathlib, sys
pathlib.Path(sys.argv[2]).write_text(pathlib.Path(sys.argv[1]).read_text().replace(os.environ['NEEDLE'], 'omitted'))
PY
  if /bin/bash "$TMP/drift/tests/ci-workflow-regression.sh" > "$TMP/drift-output" 2>&1; then
    echo "FAIL: omitted runner coverage was accepted: $needle" >&2
    exit 1
  fi
done
cp "$ROOT/scripts/check-all" "$TMP/drift/scripts/"
sed 's@/bin/bash -n@/bin/bash@' "$ROOT/.github/workflows/checks.yml" > "$TMP/drift/.github/workflows/checks.yml"
if /bin/bash "$TMP/drift/tests/ci-workflow-regression.sh" > "$TMP/drift-output" 2>&1; then
  echo 'FAIL: omitted CI syntax coverage was accepted' >&2
  exit 1
fi
printf '%s\n' 'check-all regression: passed'
