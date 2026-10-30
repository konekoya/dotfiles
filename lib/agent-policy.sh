# shellcheck shell=bash
# Shared target metadata and filesystem checks for install.sh and doctor.
# Never load agent configuration or credential contents here.

agent_policy_init() {
  AGENT_POLICY_SOURCE="$DOTFILES_DIR/agents/security.md"
  agent_policy_labels=("Codex CLI" "Claude Code" "GitHub Copilot CLI")
  agent_policy_roots=("${CODEX_HOME:-$HOME/.codex}" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "${COPILOT_HOME:-$HOME/.copilot}")
  agent_policy_suffixes=("AGENTS.md" "rules/dotfiles-security.md" "copilot-instructions.md")
}

# Refuse to traverse user-managed directory links, including dangling links.
# Absolute profile paths keep installer and CLI path resolution unambiguous.
# The caller may create absent directories only after this read-only check.
agent_policy_directory_is_safe() {
  local directory="${1%/}"
  case "$directory/" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$directory/" in
    */../*|*/./*) return 1 ;;
  esac
  while [ -n "$directory" ]; do
    [ ! -L "$directory" ] || return 1
    if [ -e "$directory" ] && [ ! -d "$directory" ]; then
      return 1
    fi
    directory="${directory%/*}"
  done
}

install_agent_policy() {
  local index label root target parent
  agent_policy_init
  if [ ! -f "$AGENT_POLICY_SOURCE" ]; then
    echo "⚠️  Canonical agent security policy is missing; skipping global policy links."
    return 0
  fi

  for index in "${!agent_policy_labels[@]}"; do
    label="${agent_policy_labels[$index]}"
    root="${agent_policy_roots[$index]%/}"
    target="$root/${agent_policy_suffixes[$index]}"
    parent="${target%/*}"
    if ! agent_policy_directory_is_safe "$parent"; then
      echo "⚠️  $label: preserving linked/conflicting directory or unsupported profile path; review README Agent credential safety."
      continue
    fi
    if [ "$index" -eq 0 ] && { [ -e "$root/AGENTS.override.md" ] || [ -L "$root/AGENTS.override.md" ]; }; then
      echo "⚠️  Codex CLI: preserving global AGENTS.override.md; integrate the policy manually in the active instructions."
      continue
    fi
    if [ -L "$target" ] && [ -f "$target" ] && [ "$target" -ef "$AGENT_POLICY_SOURCE" ]; then
      echo "🤖 $label: security policy already linked."
    elif [ -e "$target" ] || [ -L "$target" ]; then
      echo "⚠️  $label: preserving existing global instruction path; integrate the policy manually (README Agent credential safety)."
    elif mkdir -p "$parent" 2>/dev/null && ln -s "$AGENT_POLICY_SOURCE" "$target" 2>/dev/null; then
      echo "🤖 $label: linked global security policy."
    else
      echo "⚠️  $label: could not link global security policy; review README Agent credential safety."
    fi
  done
}

check_agent_policy() {
  local index label root target
  agent_policy_init
  for index in "${!agent_policy_labels[@]}"; do
    label="${agent_policy_labels[$index]}"
    root="${agent_policy_roots[$index]%/}"
    target="$root/${agent_policy_suffixes[$index]}"
    if ! agent_policy_directory_is_safe "${target%/*}"; then
      check_warn "$label: security policy directory needs manual review (README Agent credential safety)"
    elif [ "$index" -eq 0 ] && { [ -e "$root/AGENTS.override.md" ] || [ -L "$root/AGENTS.override.md" ]; }; then
      check_warn "Codex CLI: global AGENTS.override.md may mask the security policy; integrate it manually"
    elif [ -L "$target" ] && [ -f "$target" ] && [ "$target" -ef "$AGENT_POLICY_SOURCE" ]; then
      check_pass "$label: global security policy link is correct (runtime loading not checked)"
    elif [ -e "$target" ] || [ -L "$target" ]; then
      check_warn "$label: custom/conflicting instruction path preserved; security policy coverage is unverified (see README)"
    else
      check_warn "$label: optional global security policy is missing — run install.sh"
    fi
  done
}
