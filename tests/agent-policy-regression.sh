#!/bin/bash
# Description: Regression coverage for native global policy links using synthetic fixtures

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-policy-regression.XXXXXX")" || exit 1
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)" || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

setup_fixture() {
  local name="$1"
  TEST_CASE="$TEST_ROOT/$name"
  HOME="$TEST_CASE/home"
  DOTFILES_DIR="$HOME/dotfiles"
  unset CODEX_HOME CLAUDE_CONFIG_DIR COPILOT_HOME
  mkdir -p "$DOTFILES_DIR/lib" "$DOTFILES_DIR/agents" "$DOTFILES_DIR/alias" || fail "fixture creation"
  cp "$REPO_ROOT/lib/agent-policy.sh" "$DOTFILES_DIR/lib/" || fail "helper copy"
  cp "$REPO_ROOT/agents/security.md" "$REPO_ROOT/agents/tooling.md" "$DOTFILES_DIR/agents/" || fail "policy copy"
  # This file must never be sourced by policy installation or diagnostics.
  printf 'printf "synthetic-credential-must-stay-private\\n"\ntouch "%s"\n' "$TEST_CASE/env-was-sourced" > "$DOTFILES_DIR/alias/.env"
  # shellcheck source=lib/agent-policy.sh
  source "$DOTFILES_DIR/lib/agent-policy.sh"
  agent_policy_init
}

check_pass() { echo "PASS: $*"; }
check_warn() { echo "WARN: $*"; }

run_policy() {
  install_agent_policy > "$TEST_CASE/install-output" 2>&1 || fail "policy installation"
  check_agent_policy > "$TEST_CASE/doctor-output" 2>&1 || fail "policy diagnostics"
  if grep -Fq 'synthetic-credential-must-stay-private' "$TEST_CASE/"*-output; then
    fail "policy output exposed synthetic credential content"
  fi
  [ ! -e "$TEST_CASE/env-was-sourced" ] || fail "policy handling sourced a credential file"
}

target_for_index() {
  target="${agent_policy_roots[$1]}/${agent_policy_suffixes[$1]}"
}

BEGIN_PATTERN='^<!-- BEGIN dotfiles agent guidance cksum=[0-9]+-[0-9]+ \(managed by install\.sh\) -->$'
END_MARKER='<!-- END dotfiles agent guidance -->'
OLD_BEGIN='<!-- BEGIN dotfiles agent guidance (managed by install.sh) -->'

file_sum() { cksum < "$1"; }

# Independent of the helper: the block body is the security policy, a blank line, then the tooling guidance.
expected_body() {
  cat "$AGENT_POLICY_SOURCE"
  echo
  cat "$AGENT_TOOLING_SOURCE"
}

block_body_of() {
  awk '/^<!-- BEGIN dotfiles agent guidance/{inside=1; next} $0 == "<!-- END dotfiles agent guidance -->"{inside=0} inside' "$1"
}

assert_managed_block() {
  [ -f "$1" ] && [ ! -L "$1" ] || fail "$1 is not a regular managed file"
  grep -Eq "$BEGIN_PATTERN" "$1" || fail "$1 lacks the checksummed BEGIN marker"
  [ "$(grep -c '^<!-- END dotfiles agent guidance -->$' "$1")" -eq 1 ] || fail "$1 lacks one END marker"
  block_body_of "$1" | cmp -s - <(expected_body) || fail "$1 block body is not security plus tooling"
}

assert_no_temp_files() {
  local leftover
  for leftover in "$1"/.*.dotfiles-*; do
    [ ! -e "$leftover" ] || fail "temporary file left behind: $leftover"
  done
}

assert_only_agent_dirs() {
  local entries
  entries="$(ls -A "$HOME" | tr '\n' ' ')"
  [ "$entries" = ".claude .codex .copilot dotfiles " ] || fail "unexpected home entries: $entries"
}

# Block targets (Codex, Copilot) are regular managed files; Claude is linked per source.
assert_fresh_install() {
  local index
  for index in "${!agent_policy_labels[@]}"; do
    target_for_index "$index"
    if [ "${agent_policy_modes[$index]}" = block ]; then
      assert_managed_block "$target"
    else
      [ -L "$target" ] && [ "$target" -ef "$AGENT_POLICY_SOURCE" ] || fail "security link missing"
      [ -L "${agent_policy_roots[$index]}/${agent_tooling_suffixes[$index]}" ] && \
        [ "${agent_policy_roots[$index]}/${agent_tooling_suffixes[$index]}" -ef "$AGENT_TOOLING_SOURCE" ] || fail "tooling link missing"
    fi
  done
}

# The repository gets the entire policy as instructions, without an implicit import.
python3 - "$REPO_ROOT" <<'PY' || exit 1
from pathlib import Path
import sys
root = Path(sys.argv[1])
text = (root / 'AGENTS.md').read_text()
start = '<!-- BEGIN agents/security.md -->\n'
end = '<!-- END agents/security.md -->'
if text.count(start) != 1 or text.count(end) != 1:
    sys.exit('FAIL: repository policy markers must occur once')
block = text.split(start)[1].split(end)[0]
if block != (root / 'agents/security.md').read_text():
    sys.exit('FAIL: AGENTS.md policy differs from canonical policy')
PY


setup_fixture fresh
cp "$AGENT_POLICY_SOURCE" "$TEST_CASE/security-original"
run_policy
assert_fresh_install
assert_only_agent_dirs
touch "$TEST_CASE/mode-reference"
target_for_index 0
[ "$(stat -f '%Lp' "$target")" = "$(stat -f '%Lp' "$TEST_CASE/mode-reference")" ] || fail "new managed file does not have default permissions"
cp "$HOME/.codex/AGENTS.md" "$TEST_CASE/codex-first"
cp "$HOME/.copilot/copilot-instructions.md" "$TEST_CASE/copilot-first"
[ "$(grep -c '^PASS:' "$TEST_CASE/doctor-output")" -eq 4 ] || fail "working entry points not recognized"
grep -Fq '(runtime loading not checked)' "$TEST_CASE/doctor-output" || fail "diagnostics must not claim runtime loading"
grep -Eqi 'orca' "$TEST_CASE/doctor-output" "$TEST_CASE/install-output" && fail "Orca support was claimed"
run_policy
[ "$(grep -c 'managed guidance block already current' "$TEST_CASE/install-output")" -eq 2 ] || fail "repeated install rewrote managed blocks"
[ "$(grep -c 'security policy already linked' "$TEST_CASE/install-output")" -eq 1 ] || fail "security link not idempotent"
[ "$(grep -c 'tooling guidance already linked' "$TEST_CASE/install-output")" -eq 1 ] || fail "tooling link not idempotent"
cmp -s "$HOME/.codex/AGENTS.md" "$TEST_CASE/codex-first" || fail "Codex file changed on rerun"
cmp -s "$HOME/.copilot/copilot-instructions.md" "$TEST_CASE/copilot-first" || fail "Copilot file changed on rerun"
[ "$(grep -c '^PASS:' "$TEST_CASE/doctor-output")" -eq 4 ] || fail "rerun not recognized"

# Links track canonical edits; managed blocks go stale, doctor says so, and a rerun refreshes them.
printf '\nSynthetic policy update.\n' >> "$AGENT_POLICY_SOURCE"
printf '\nSynthetic tooling update.\n' >> "$AGENT_TOOLING_SOURCE"
cmp -s "$HOME/.claude/rules/dotfiles-security.md" "$AGENT_POLICY_SOURCE" || fail "security link became stale"
cmp -s "$HOME/.claude/rules/dotfiles-tooling.md" "$AGENT_TOOLING_SOURCE" || fail "tooling link became stale"
check_agent_policy > "$TEST_CASE/doctor-output" 2>&1
[ "$(grep -c 'managed guidance block is stale' "$TEST_CASE/doctor-output")" -eq 2 ] || fail "stale blocks not reported"
[ "$(grep -c '^PASS:' "$TEST_CASE/doctor-output")" -eq 2 ] || fail "stale blocks counted as healthy"
run_policy
[ "$(grep -c 'refreshed managed guidance block' "$TEST_CASE/install-output")" -eq 2 ] || fail "stale blocks not refreshed"
assert_fresh_install
[ "$(grep -c '^PASS:' "$TEST_CASE/doctor-output")" -eq 4 ] || fail "refreshed blocks not recognized"

# The old marker form without a checksum is accepted as stale and upgraded in place.
setup_fixture old-marker
mkdir -p "$HOME/.codex"
{ printf 'before\n'; echo "$OLD_BEGIN"; expected_body; echo "$END_MARKER"; printf 'after\n'; } > "$HOME/.codex/AGENTS.md"
check_agent_policy > "$TEST_CASE/doctor-output" 2>&1
grep -Fq 'Codex CLI: managed guidance block is stale' "$TEST_CASE/doctor-output" || fail "old marker not reported stale"
run_policy
[ "$(sed -n 1p "$HOME/.codex/AGENTS.md")" = before ] && [ "$(tail -n 1 "$HOME/.codex/AGENTS.md")" = after ] || fail "text around the block changed"
assert_managed_block "$HOME/.codex/AGENTS.md"

# Legacy security links become managed blocks without writing through the link.
for form in absolute relative; do
  setup_fixture "legacy-$form"
  cp "$AGENT_POLICY_SOURCE" "$TEST_CASE/security-original"
  mkdir -p "$HOME/.codex" "$HOME/.copilot" "$HOME/.claude/rules"
  if [ "$form" = absolute ]; then
    ln -s "$AGENT_POLICY_SOURCE" "$HOME/.codex/AGENTS.md"
  else
    ln -s ../dotfiles/agents/security.md "$HOME/.codex/AGENTS.md"
  fi
  ln -s "$AGENT_POLICY_SOURCE" "$HOME/.copilot/copilot-instructions.md"
  ln -s "$AGENT_POLICY_SOURCE" "$HOME/.claude/rules/dotfiles-security.md"
  check_agent_policy > "$TEST_CASE/legacy-doctor" 2>&1
  [ "$(grep -c 'security policy link has no tooling guidance' "$TEST_CASE/legacy-doctor")" -eq 2 ] || fail "legacy links not reported"
  run_policy
  [ "$(grep -c 'replaced the security policy link with a managed guidance block' "$TEST_CASE/install-output")" -eq 2 ] || fail "legacy links not migrated"
  assert_fresh_install
  cmp -s "$AGENT_POLICY_SOURCE" "$TEST_CASE/security-original" || fail "canonical policy was written through a link"
  [ ! -L "$AGENT_POLICY_SOURCE" ] || fail "canonical policy was replaced"
  assert_no_temp_files "$HOME/.codex"
done

# Text around a managed block survives a refresh, and an existing file's mode is kept.
setup_fixture user-content
mkdir -p "$HOME/.codex"
{
  printf 'synthetic-credential-must-stay-private\n'
  printf 'user line above\n'
  echo "$OLD_BEGIN"
  printf 'old managed text\n'
  echo "$END_MARKER"
  printf 'user line below\n\nlast line without newline'
} > "$HOME/.codex/AGENTS.md"
chmod 660 "$HOME/.codex/AGENTS.md"
run_policy
assert_managed_block "$HOME/.codex/AGENTS.md"
[ "$(sed -n 1,2p "$HOME/.codex/AGENTS.md" | tr '\n' '|')" = 'synthetic-credential-must-stay-private|user line above|' ] || fail "text above the block changed"
[ "$(tail -n 3 "$HOME/.codex/AGENTS.md" | tr '\n' '|')" = 'user line below||last line without newline' ] || fail "text below the block changed"
[ "$(stat -f '%Lp' "$HOME/.codex/AGENTS.md")" = 660 ] || fail "file mode changed on rewrite"
cp "$HOME/.codex/AGENTS.md" "$TEST_CASE/after-first"
run_policy
cmp -s "$HOME/.codex/AGENTS.md" "$TEST_CASE/after-first" || fail "second run changed a current file"
# A hand edit inside the markers is overwritten, because the installer owns that text.
awk -v end="$END_MARKER" '$0 == end {print "hand edit inside block"} {print}' "$HOME/.codex/AGENTS.md" > "$TEST_CASE/edited"
cp "$TEST_CASE/edited" "$HOME/.codex/AGENTS.md"
run_policy
assert_managed_block "$HOME/.codex/AGENTS.md"
grep -Fq 'hand edit inside block' "$HOME/.codex/AGENTS.md" && fail "edit inside the block survived"

# Unmarked and malformed files are never rewritten; the installer explains the manual step.
for kind in unmarked only-begin only-end duplicate reversed; do
  setup_fixture "markers-$kind"
  mkdir -p "$HOME/.codex" "$HOME/.copilot"
  case "$kind" in
    unmarked) printf 'synthetic-credential-must-stay-private\n' > "$TEST_CASE/custom.md" ;;
    only-begin) { echo "$OLD_BEGIN"; echo 'synthetic-credential-must-stay-private'; } > "$TEST_CASE/custom.md" ;;
    only-end) { echo 'synthetic-credential-must-stay-private'; echo "$END_MARKER"; } > "$TEST_CASE/custom.md" ;;
    duplicate) { echo "$OLD_BEGIN"; echo "$END_MARKER"; echo "$OLD_BEGIN"; echo "$END_MARKER"; echo 'synthetic-credential-must-stay-private'; } > "$TEST_CASE/custom.md" ;;
    reversed) { echo "$END_MARKER"; echo "$OLD_BEGIN"; echo 'synthetic-credential-must-stay-private'; } > "$TEST_CASE/custom.md" ;;
  esac
  cp "$TEST_CASE/custom.md" "$HOME/.codex/AGENTS.md"
  cp "$TEST_CASE/custom.md" "$HOME/.copilot/copilot-instructions.md"
  run_policy
  run_policy
  cmp -s "$HOME/.codex/AGENTS.md" "$TEST_CASE/custom.md" || fail "$kind Codex file changed"
  cmp -s "$HOME/.copilot/copilot-instructions.md" "$TEST_CASE/custom.md" || fail "$kind Copilot file changed"
  if [ "$kind" = unmarked ]; then
    [ "$(grep -c 'add the managed guidance block manually' "$TEST_CASE/install-output")" -eq 2 ] || fail "unmarked files not explained"
  else
    [ "$(grep -c 'unbalanced guidance block markers' "$TEST_CASE/install-output")" -eq 2 ] || fail "malformed markers not explained"
    [ "$(grep -c 'guidance block markers are unbalanced' "$TEST_CASE/doctor-output")" -eq 2 ] || fail "malformed markers not diagnosed"
  fi
  [ "$(grep -c 'coverage is unverified' "$TEST_CASE/doctor-output")" -eq 2 ] || fail "custom files incorrectly certified"
done

# All kinds of occupied instruction paths survive, including dangling links.
for kind in file directory symlink dangling; do
  setup_fixture "conflict-$kind"
  printf 'synthetic-credential-must-stay-private\n' > "$TEST_CASE/custom.md"
  occupied=("${agent_policy_roots[0]}/${agent_policy_suffixes[0]}" "${agent_policy_roots[1]}/${agent_policy_suffixes[1]}" \
    "${agent_policy_roots[1]}/${agent_tooling_suffixes[1]}" "${agent_policy_roots[2]}/${agent_policy_suffixes[2]}")
  for target in "${occupied[@]}"; do
    mkdir -p "${target%/*}"
    case "$kind" in
      file) cp "$TEST_CASE/custom.md" "$target" ;;
      directory) mkdir "$target" ;;
      symlink) ln -s "$TEST_CASE/custom.md" "$target" ;;
      dangling) ln -s "$TEST_CASE/missing.md" "$target" ;;
    esac
  done
  run_policy
  run_policy
  for target in "${occupied[@]}"; do
    case "$kind" in
      file) [ ! -L "$target" ] && cmp -s "$target" "$TEST_CASE/custom.md" || fail "custom instructions changed" ;;
      directory) [ -d "$target" ] && [ -z "$(ls -A "$target")" ] || fail "instruction directory changed" ;;
      symlink) [ "$(readlink "$target")" = "$TEST_CASE/custom.md" ] || fail "custom symlink changed" ;;
      dangling) [ "$(readlink "$target")" = "$TEST_CASE/missing.md" ] || fail "dangling symlink changed" ;;
    esac
  done
  [ "$(grep -c 'preserving existing global instruction path' "$TEST_CASE/install-output")" -eq 2 ] || [ "$kind" != file ] || fail "Claude conflicts not reported"
  [ "$(grep -c 'preserving existing global instruction path' "$TEST_CASE/install-output")" -eq 4 ] || [ "$kind" = file ] || fail "conflicts not reported"
  [ "$(grep -c 'coverage is unverified' "$TEST_CASE/doctor-output")" -eq 4 ] || fail "custom paths incorrectly certified"
done

# One occupied Claude path must not stop the other source from being linked.
setup_fixture partial-claude
mkdir -p "$HOME/.claude/rules"
printf 'synthetic-credential-must-stay-private\n' > "$HOME/.claude/rules/dotfiles-tooling.md"
run_policy
[ -L "$HOME/.claude/rules/dotfiles-security.md" ] || fail "security link skipped because tooling path was occupied"

# Parent links/files must not redirect policy writes into user-managed directories.
for kind in symlink dangling file; do
  setup_fixture "parent-$kind"
  mkdir "$TEST_CASE/external"
  for root in "${agent_policy_roots[@]}"; do
    case "$kind" in
      symlink) ln -s "$TEST_CASE/external" "$root" ;;
      dangling) ln -s "$TEST_CASE/missing" "$root" ;;
      file) printf 'synthetic-credential-must-stay-private\n' > "$root" ;;
    esac
  done
  run_policy
  [ -z "$(ls -A "$TEST_CASE/external")" ] || fail "policy installer followed a parent link"
  [ "$(grep -c 'preserving linked/conflicting directory' "$TEST_CASE/install-output")" -eq 3 ] || fail "unsafe parents not reported"
done

for nested in rules instructions; do
  setup_fixture "nested-parent-$nested"
  mkdir -p "$HOME/.claude" "$TEST_CASE/external"
  ln -s "$TEST_CASE/external" "$HOME/.claude/rules"
  run_policy
  [ -z "$(ls -A "$TEST_CASE/external")" ] || fail "nested parent link followed"
done

# Codex uses only one global file, and an override masks it. Never write a file that is masked.
for kind in file dangling; do
  setup_fixture "override-$kind"
  mkdir -p "$HOME/.codex"
  if [ "$kind" = file ]; then
    printf 'synthetic-credential-must-stay-private\n' > "$HOME/.codex/AGENTS.override.md"
  else
    ln -s "$TEST_CASE/missing" "$HOME/.codex/AGENTS.override.md"
  fi
  run_policy
  [ ! -e "$HOME/.codex/AGENTS.md" ] && [ ! -L "$HOME/.codex/AGENTS.md" ] || fail "Codex override ignored"
  grep -Fq 'may mask the security policy and tooling guidance' "$TEST_CASE/doctor-output" || fail "Codex masking not reported"
  assert_managed_block "$HOME/.copilot/copilot-instructions.md"
done

# Adding an override after installation must also invalidate the diagnostic pass.
setup_fixture later-override
run_policy
: > "$HOME/.codex/AGENTS.override.md"
run_policy
grep -Fq 'may mask the security policy' "$TEST_CASE/doctor-output" || fail "later override not reported"

# Claude's existing main instructions coexist with its independent global rules.
setup_fixture claude-main
mkdir -p "$HOME/.claude"
printf 'synthetic-credential-must-stay-private\n' > "$HOME/.claude/CLAUDE.md"
cp "$HOME/.claude/CLAUDE.md" "$TEST_CASE/original"
run_policy
cmp -s "$HOME/.claude/CLAUDE.md" "$TEST_CASE/original" || fail "Claude main instructions changed"
[ -L "$HOME/.claude/rules/dotfiles-security.md" ] && [ -L "$HOME/.claude/rules/dotfiles-tooling.md" ] || fail "Claude rules missing"

setup_fixture custom-profiles
CODEX_HOME="$HOME/profiles/codex"
CLAUDE_CONFIG_DIR="$HOME/profiles/claude"
COPILOT_HOME="$HOME/profiles/copilot"
run_policy
assert_fresh_install
[ ! -e "$HOME/.codex" ] && [ ! -e "$HOME/.claude" ] && [ ! -e "$HOME/.copilot" ] || fail "default profile written despite custom profile"

setup_fixture relative-profile
CODEX_HOME='relative-profile'
run_policy
[ ! -e relative-profile ] || fail "relative profile written"
grep -Fq 'unsupported profile path' "$TEST_CASE/install-output" || fail "relative profile not reported"

# A read-only profile directory leaves the old block untouched and reports the failure.
setup_fixture unwritable
mkdir -p "$HOME/.codex"
{ echo "$OLD_BEGIN"; echo old; echo "$END_MARKER"; } > "$HOME/.codex/AGENTS.md"
cp "$HOME/.codex/AGENTS.md" "$TEST_CASE/original"
chmod 555 "$HOME/.codex"
install_agent_policy > "$TEST_CASE/install-output" 2>&1
chmod 755 "$HOME/.codex"
cmp -s "$HOME/.codex/AGENTS.md" "$TEST_CASE/original" || fail "failed rewrite changed the file"
grep -Fq 'could not write managed guidance block' "$TEST_CASE/install-output" || fail "failed rewrite not reported"
assert_no_temp_files "$HOME/.codex"

setup_fixture missing
check_agent_policy > "$TEST_CASE/doctor-output" 2>&1 || fail "optional missing policy caused failure"
[ "$(grep -c 'optional global security policy and tooling guidance are missing' "$TEST_CASE/doctor-output")" -eq 2 ] || fail "missing block targets not warned"
[ "$(grep -c 'optional global security policy is missing' "$TEST_CASE/doctor-output")" -eq 1 ] || fail "missing security link not warned"
[ "$(grep -c 'optional global tooling guidance is missing' "$TEST_CASE/doctor-output")" -eq 1 ] || fail "missing tooling link not warned"
[ ! -e "$HOME/.codex" ] || fail "diagnostics created directories"

# Tooling guidance may be absent; the security policy is still delivered, and the rest follows once it appears.
cp "$AGENT_TOOLING_SOURCE" "$TEST_CASE/tooling-copy"
rm "$AGENT_TOOLING_SOURCE"
run_policy
grep -Fq 'tooling guidance is missing' "$TEST_CASE/install-output" || fail "missing tooling source not warned"
grep -Fq 'tooling.md is missing' "$TEST_CASE/doctor-output" || fail "missing tooling source not diagnosed"
cmp -s "$HOME/.codex/AGENTS.md" <(echo "$(sed -n 1p "$HOME/.codex/AGENTS.md")"; cat "$AGENT_POLICY_SOURCE"; echo "$END_MARKER") || fail "security-only block is wrong"
[ ! -e "$HOME/.claude/rules/dotfiles-tooling.md" ] && [ -L "$HOME/.claude/rules/dotfiles-security.md" ] || fail "Claude links wrong without tooling source"
cp "$TEST_CASE/tooling-copy" "$AGENT_TOOLING_SOURCE"
run_policy
assert_fresh_install

# Canonical sources are never modified, and a missing policy skips installation.
rm "$AGENT_POLICY_SOURCE"
install_agent_policy > "$TEST_CASE/install-output" 2>&1 || fail "missing canonical source caused failure"
grep -Fq 'Canonical agent security policy is missing' "$TEST_CASE/install-output" || fail "missing canonical source not warned"

echo "PASS: agent policy regression suite"
