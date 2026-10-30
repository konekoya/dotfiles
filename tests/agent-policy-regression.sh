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
  cp "$REPO_ROOT/agents/security.md" "$DOTFILES_DIR/agents/" || fail "policy copy"
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
run_policy
for index in "${!agent_policy_labels[@]}"; do
  target_for_index "$index"
  [ -L "$target" ] && [ "$target" -ef "$AGENT_POLICY_SOURCE" ] || fail "native instruction link missing"
  cmp -s "$target" "$AGENT_POLICY_SOURCE" || fail "native entry point did not contain full policy"
done
run_policy
[ "$(grep -c 'security policy already linked' "$TEST_CASE/install-output")" -eq 3 ] || fail "repeated install not idempotent"
[ "$(grep -c '^PASS:' "$TEST_CASE/doctor-output")" -eq 3 ] || fail "working links not recognized"

# Each native entry point must remain live when the canonical policy changes.
printf '\nSynthetic policy update.\n' >> "$AGENT_POLICY_SOURCE"
for index in "${!agent_policy_labels[@]}"; do
  target_for_index "$index"
  cmp -s "$target" "$AGENT_POLICY_SOURCE" || fail "policy link became stale"
done

# All kinds of occupied instruction paths survive, including dangling links.
for kind in file directory symlink dangling; do
  setup_fixture "conflict-$kind"
  printf 'synthetic-credential-must-stay-private\n' > "$TEST_CASE/custom.md"
  for index in "${!agent_policy_labels[@]}"; do
    target_for_index "$index"
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
  for index in "${!agent_policy_labels[@]}"; do
    target_for_index "$index"
    case "$kind" in
      file) [ ! -L "$target" ] && cmp -s "$target" "$TEST_CASE/custom.md" || fail "custom instructions changed" ;;
      directory) [ -d "$target" ] && [ -z "$(ls -A "$target")" ] || fail "instruction directory changed" ;;
      symlink) [ "$(readlink "$target")" = "$TEST_CASE/custom.md" ] || fail "custom symlink changed" ;;
      dangling) [ "$(readlink "$target")" = "$TEST_CASE/missing.md" ] || fail "dangling symlink changed" ;;
    esac
  done
  [ "$(grep -c 'preserving existing global instruction path' "$TEST_CASE/install-output")" -eq 3 ] || fail "conflicts not reported"
  [ "$(grep -c 'coverage is unverified' "$TEST_CASE/doctor-output")" -eq 3 ] || fail "custom paths incorrectly certified"
done

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

setup_fixture nested-parent
mkdir -p "$HOME/.claude" "$TEST_CASE/external"
ln -s "$TEST_CASE/external" "$HOME/.claude/rules"
run_policy
[ -z "$(ls -A "$TEST_CASE/external")" ] || fail "nested parent link followed"

# Codex uses only one global file. Never create a policy that an override masks.
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
  grep -Fq 'may mask the security policy' "$TEST_CASE/doctor-output" || fail "Codex masking not reported"
done

# Adding an override after installation must also invalidate the diagnostic pass.
setup_fixture later-override
run_policy
: > "$HOME/.codex/AGENTS.override.md"
run_policy
grep -Fq 'may mask the security policy' "$TEST_CASE/doctor-output" || fail "later override not reported"

# Claude's existing main instructions coexist with its independent global rule.
setup_fixture claude-main
mkdir -p "$HOME/.claude"
printf 'synthetic-credential-must-stay-private\n' > "$HOME/.claude/CLAUDE.md"
cp "$HOME/.claude/CLAUDE.md" "$TEST_CASE/original"
run_policy
cmp -s "$HOME/.claude/CLAUDE.md" "$TEST_CASE/original" || fail "Claude main instructions changed"
[ -L "$HOME/.claude/rules/dotfiles-security.md" ] || fail "Claude rule missing"

setup_fixture custom-profiles
CODEX_HOME="$HOME/profiles/codex"
CLAUDE_CONFIG_DIR="$HOME/profiles/claude"
COPILOT_HOME="$HOME/profiles/copilot"
run_policy
for index in "${!agent_policy_labels[@]}"; do
  target_for_index "$index"
  [ -L "$target" ] || fail "custom profile policy missing"
done
[ ! -e "$HOME/.codex" ] && [ ! -e "$HOME/.claude" ] && [ ! -e "$HOME/.copilot" ] || fail "default profile written despite custom profile"

setup_fixture relative-profile
CODEX_HOME='relative-profile'
run_policy
[ ! -e relative-profile ] || fail "relative profile written"
grep -Fq 'unsupported profile path' "$TEST_CASE/install-output" || fail "relative profile not reported"

setup_fixture relative-link
mkdir -p "$HOME/.codex"
ln -s ../dotfiles/agents/security.md "$HOME/.codex/AGENTS.md"
run_policy
grep -Fq 'Codex CLI: security policy already linked' "$TEST_CASE/install-output" || fail "relative owned link not recognized"

setup_fixture missing
check_agent_policy > "$TEST_CASE/doctor-output" 2>&1 || fail "optional missing policy caused failure"
[ "$(grep -c 'optional global security policy is missing' "$TEST_CASE/doctor-output")" -eq 3 ] || fail "missing policy not warned"
[ ! -e "$HOME/.codex" ] || fail "diagnostics created directories"
rm "$AGENT_POLICY_SOURCE"
install_agent_policy > "$TEST_CASE/install-output" 2>&1 || fail "missing canonical source caused failure"
grep -Fq 'Canonical agent security policy is missing' "$TEST_CASE/install-output" || fail "missing canonical source not warned"

echo "PASS: agent policy regression suite"
