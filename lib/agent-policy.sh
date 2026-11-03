# shellcheck shell=bash
# Shared target metadata and filesystem checks for install.sh and doctor.
# Never load agent configuration or credential contents here.
#
# Agents with several instruction files (Claude Code) get one symlink per source.
# Agents with a single global file (Codex CLI, GitHub Copilot CLI) get a managed
# block: the security policy followed by the tooling guidance, delimited by marker
# lines. The installer owns only the text between the markers. The BEGIN marker
# carries a checksum of the block body so doctor can detect a stale block by
# reading marker lines alone.

agent_policy_init() {
  AGENT_POLICY_SOURCE="$DOTFILES_DIR/agents/security.md"
  AGENT_TOOLING_SOURCE="$DOTFILES_DIR/agents/tooling.md"
  agent_policy_labels=("Codex CLI" "Claude Code" "GitHub Copilot CLI")
  agent_policy_roots=("${CODEX_HOME:-$HOME/.codex}" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "${COPILOT_HOME:-$HOME/.copilot}")
  agent_policy_suffixes=("AGENTS.md" "rules/dotfiles-security.md" "copilot-instructions.md")
  # block: one managed file carries security and tooling; link: one symlink each.
  agent_policy_modes=(block link block)
  agent_tooling_suffixes=("" "rules/dotfiles-tooling.md" "")
  # A global override file takes precedence over the main file and masks it.
  agent_policy_overrides=("AGENTS.override.md" "" "")
  AGENT_POLICY_BLOCK_END='<!-- END dotfiles agent guidance -->'
  AGENT_POLICY_BLOCK_PATTERN='^<!-- BEGIN dotfiles agent guidance( cksum=[0-9]+-[0-9]+)? \(managed by install\.sh\) -->$|^<!-- END dotfiles agent guidance -->$'
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

agent_policy_owned_link() {
  [ -L "$1" ] && [ -f "$1" ] && [ "$1" -ef "$2" ]
}

# Print a canonical file, ending with a newline even if the file does not.
agent_policy_emit_file() {
  cat "$1"
  [ -z "$(tail -c 1 "$1")" ] || echo
}

# The block body: security policy, then tooling guidance when it exists.
agent_policy_render_body() {
  agent_policy_emit_file "$AGENT_POLICY_SOURCE"
  if [ -f "$AGENT_TOOLING_SOURCE" ]; then
    echo
    agent_policy_emit_file "$AGENT_TOOLING_SOURCE"
  fi
}

agent_policy_checksum() {
  agent_policy_render_body | cksum | {
    read -r sum size _
    echo "$sum-$size"
  }
}

agent_policy_render_block() {
  echo "<!-- BEGIN dotfiles agent guidance cksum=$(agent_policy_checksum) (managed by install.sh) -->"
  agent_policy_render_body
  echo "$AGENT_POLICY_BLOCK_END"
}

# Find the managed-block markers in a file. Only marker lines are read from the
# output of grep, so no other file content reaches this function or the terminal.
# Sets AGENT_POLICY_BEGIN_COUNT/END_COUNT, the first BEGIN/END line numbers, and
# the BEGIN line's checksum ("none" for the old form without one).
agent_policy_scan_markers() {
  local line number text
  AGENT_POLICY_BEGIN_COUNT=0
  AGENT_POLICY_END_COUNT=0
  AGENT_POLICY_BEGIN_LINE=0
  AGENT_POLICY_END_LINE=0
  AGENT_POLICY_BEGIN_CHECKSUM=none
  while IFS= read -r line; do
    number="${line%%:*}"
    text="${line#*:}"
    if [ "$text" = "$AGENT_POLICY_BLOCK_END" ]; then
      AGENT_POLICY_END_COUNT=$((AGENT_POLICY_END_COUNT + 1))
      [ "$AGENT_POLICY_END_LINE" -ne 0 ] || AGENT_POLICY_END_LINE="$number"
    else
      AGENT_POLICY_BEGIN_COUNT=$((AGENT_POLICY_BEGIN_COUNT + 1))
      if [ "$AGENT_POLICY_BEGIN_LINE" -eq 0 ]; then
        AGENT_POLICY_BEGIN_LINE="$number"
        case "$text" in
          *' cksum='*)
            AGENT_POLICY_BEGIN_CHECKSUM="${text#*cksum=}"
            AGENT_POLICY_BEGIN_CHECKSUM="${AGENT_POLICY_BEGIN_CHECKSUM%% *}"
            ;;
        esac
      fi
    fi
  done < <(grep -anE "$AGENT_POLICY_BLOCK_PATTERN" "$1" 2>/dev/null)
}

# Classify a single-file target in AGENT_POLICY_BLOCK_STATE:
#   absent     nothing at the path
#   legacy     installer-owned symlink to the security policy (no tooling guidance)
#   other      symlink, directory, or unreadable path owned by the user
#   unmarked   regular file without our markers
#   malformed  markers that are duplicated, unpaired, or in the wrong order
#   stale      managed block whose checksum differs from the canonical content
#   current    managed block whose checksum matches the canonical content
agent_policy_block_state() {
  local target="$1"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    AGENT_POLICY_BLOCK_STATE=absent
  elif agent_policy_owned_link "$target" "$AGENT_POLICY_SOURCE"; then
    AGENT_POLICY_BLOCK_STATE=legacy
  elif [ -L "$target" ] || [ ! -f "$target" ] || [ ! -r "$target" ]; then
    AGENT_POLICY_BLOCK_STATE=other
  else
    agent_policy_scan_markers "$target"
    if [ "$AGENT_POLICY_BEGIN_COUNT" -eq 0 ] && [ "$AGENT_POLICY_END_COUNT" -eq 0 ]; then
      AGENT_POLICY_BLOCK_STATE=unmarked
    elif [ "$AGENT_POLICY_BEGIN_COUNT" -ne 1 ] || [ "$AGENT_POLICY_END_COUNT" -ne 1 ] || \
      [ "$AGENT_POLICY_BEGIN_LINE" -ge "$AGENT_POLICY_END_LINE" ]; then
      AGENT_POLICY_BLOCK_STATE=malformed
    elif [ "$AGENT_POLICY_BEGIN_CHECKSUM" = "$(agent_policy_checksum)" ]; then
      AGENT_POLICY_BLOCK_STATE=current
    else
      AGENT_POLICY_BLOCK_STATE=stale
    fi
  fi
}

# Install side only: replace or create the managed block. The old file is
# untouched unless the new content is complete. A rewrite keeps the existing
# file's mode; a new file gets default permissions.
agent_policy_write_block() {
  local target="$1" state="$2" block tmp status=0
  local parent="${target%/*}"
  block="$(mktemp "${TMPDIR:-/tmp}/dotfiles-guidance.XXXXXX")" || return 1
  agent_policy_render_block > "$block" || { rm -f "$block"; return 1; }
  tmp="$parent/.${target##*/}.dotfiles-$$"
  case "$state" in
    absent)
      mkdir -p "$parent" 2>/dev/null && (set -C; cat "$block" > "$target") 2>/dev/null || status=1
      ;;
    legacy)
      # Rename replaces the link itself; the canonical policy is never written through it.
      (set -C; cat "$block" > "$tmp") 2>/dev/null && mv -f "$tmp" "$target" 2>/dev/null || status=1
      ;;
    stale)
      if cp -p "$target" "$tmp" 2>/dev/null; then
        {
          [ "$AGENT_POLICY_BEGIN_LINE" -le 1 ] || head -n "$((AGENT_POLICY_BEGIN_LINE - 1))" "$target"
          cat "$block"
          tail -n "+$((AGENT_POLICY_END_LINE + 1))" "$target"
        } > "$tmp" 2>/dev/null && mv -f "$tmp" "$target" 2>/dev/null || status=1
      else
        status=1
      fi
      ;;
    *) status=1 ;;
  esac
  rm -f "$block"
  [ "$status" -eq 0 ] || rm -f "$tmp"
  return "$status"
}

# Whether the block already in a marked file is byte-identical to the canonical one.
agent_policy_block_matches() {
  local target="$1" block result=1
  block="$(mktemp "${TMPDIR:-/tmp}/dotfiles-guidance.XXXXXX")" || return 1
  agent_policy_render_block > "$block"
  if [ "$(sed -n "${AGENT_POLICY_BEGIN_LINE},${AGENT_POLICY_END_LINE}p" "$target" | cksum)" = "$(cksum < "$block")" ]; then
    result=0
  fi
  rm -f "$block"
  return "$result"
}

agent_policy_install_block() {
  local label="$1" target="$2" state
  agent_policy_block_state "$target"
  state="$AGENT_POLICY_BLOCK_STATE"
  if [ "$state" = current ] && ! agent_policy_block_matches "$target"; then
    state=stale
  fi
  case "$state" in
    current) echo "🤖 $label: managed guidance block already current." ;;
    absent|legacy|stale)
      if agent_policy_write_block "$target" "$state"; then
        case "$state" in
          absent) echo "🤖 $label: created global security policy and tooling guidance block." ;;
          legacy) echo "🤖 $label: replaced the security policy link with a managed guidance block." ;;
          stale) echo "🤖 $label: refreshed managed guidance block." ;;
        esac
      else
        echo "⚠️  $label: could not write managed guidance block; review README Agent credential safety."
      fi
      ;;
    unmarked)
      echo "⚠️  $label: preserving existing global instructions; add the managed guidance block manually (README Agent credential safety)."
      ;;
    malformed)
      echo "⚠️  $label: preserving global instructions with unbalanced guidance block markers; repair them manually (README Agent credential safety)."
      ;;
    *)
      echo "⚠️  $label: preserving existing global instruction path; integrate the policy manually (README Agent credential safety)."
      ;;
  esac
}

# Link one canonical file at a native entry point when vacant.
agent_policy_install_link() {
  local label="$1" noun="$2" source="$3" target="$4"
  if agent_policy_owned_link "$target" "$source"; then
    echo "🤖 $label: $noun already linked."
  elif [ -e "$target" ] || [ -L "$target" ]; then
    echo "⚠️  $label: preserving existing global instruction path; integrate the $noun manually (README Agent credential safety)."
  elif mkdir -p "${target%/*}" 2>/dev/null && ln -s "$source" "$target" 2>/dev/null; then
    echo "🤖 $label: linked global $noun."
  else
    echo "⚠️  $label: could not link global $noun; review README Agent credential safety."
  fi
}

install_agent_policy() {
  local index label root target tooling_target parent override
  agent_policy_init
  if [ ! -f "$AGENT_POLICY_SOURCE" ]; then
    echo "⚠️  Canonical agent security policy is missing; skipping global policy links."
    return 0
  fi
  if [ ! -f "$AGENT_TOOLING_SOURCE" ]; then
    echo "⚠️  Canonical agent tooling guidance is missing; installing the security policy only."
  fi

  for index in "${!agent_policy_labels[@]}"; do
    label="${agent_policy_labels[$index]}"
    root="${agent_policy_roots[$index]%/}"
    target="$root/${agent_policy_suffixes[$index]}"
    parent="${target%/*}"
    override="${agent_policy_overrides[$index]}"
    if ! agent_policy_directory_is_safe "$parent"; then
      echo "⚠️  $label: preserving linked/conflicting directory or unsupported profile path; review README Agent credential safety."
      continue
    fi
    if [ -n "$override" ] && { [ -e "$root/$override" ] || [ -L "$root/$override" ]; }; then
      echo "⚠️  $label: preserving global $override; integrate the security policy and tooling guidance manually in the active instructions."
      continue
    fi
    if [ "${agent_policy_modes[$index]}" = block ]; then
      agent_policy_install_block "$label" "$target"
      continue
    fi
    agent_policy_install_link "$label" "security policy" "$AGENT_POLICY_SOURCE" "$target"
    [ -f "$AGENT_TOOLING_SOURCE" ] || continue
    tooling_target="$root/${agent_tooling_suffixes[$index]}"
    if agent_policy_directory_is_safe "${tooling_target%/*}"; then
      agent_policy_install_link "$label" "tooling guidance" "$AGENT_TOOLING_SOURCE" "$tooling_target"
    else
      echo "⚠️  $label: preserving linked/conflicting directory or unsupported profile path for tooling guidance; review README Agent credential safety."
    fi
  done
}

check_agent_policy_link() {
  local label="$1" noun="$2" source="$3" target="$4"
  if ! agent_policy_directory_is_safe "${target%/*}"; then
    check_warn "$label: $noun directory needs manual review (README Agent credential safety)"
  elif agent_policy_owned_link "$target" "$source"; then
    check_pass "$label: global $noun link is correct (runtime loading not checked)"
  elif [ -e "$target" ] || [ -L "$target" ]; then
    check_warn "$label: custom/conflicting instruction path preserved; $noun coverage is unverified (see README)"
  else
    check_warn "$label: optional global $noun is missing — run install.sh"
  fi
}

check_agent_policy_block() {
  local label="$1" target="$2"
  agent_policy_block_state "$target"
  case "$AGENT_POLICY_BLOCK_STATE" in
    current) check_pass "$label: managed security and tooling block checksum is current (runtime loading not checked)" ;;
    stale) check_warn "$label: managed guidance block is stale — run install.sh" ;;
    legacy) check_warn "$label: security policy link has no tooling guidance — run install.sh to replace it with the managed block" ;;
    absent) check_warn "$label: optional global security policy and tooling guidance are missing — run install.sh" ;;
    malformed) check_warn "$label: guidance block markers are unbalanced; security and tooling coverage is unverified (see README)" ;;
    *) check_warn "$label: custom/conflicting instruction path preserved; security policy and tooling coverage is unverified (see README)" ;;
  esac
}

check_agent_policy() {
  local index label root target override
  agent_policy_init
  if [ ! -f "$AGENT_TOOLING_SOURCE" ]; then
    check_warn "Agent tooling guidance source agents/tooling.md is missing"
  fi
  for index in "${!agent_policy_labels[@]}"; do
    label="${agent_policy_labels[$index]}"
    root="${agent_policy_roots[$index]%/}"
    target="$root/${agent_policy_suffixes[$index]}"
    override="${agent_policy_overrides[$index]}"
    if ! agent_policy_directory_is_safe "${target%/*}"; then
      check_warn "$label: security policy directory needs manual review (README Agent credential safety)"
    elif [ -n "$override" ] && { [ -e "$root/$override" ] || [ -L "$root/$override" ]; }; then
      check_warn "$label: global $override may mask the security policy and tooling guidance; integrate them manually"
    elif [ "${agent_policy_modes[$index]}" = block ]; then
      check_agent_policy_block "$label" "$target"
    else
      check_agent_policy_link "$label" "security policy" "$AGENT_POLICY_SOURCE" "$target"
      if [ -f "$AGENT_TOOLING_SOURCE" ]; then
        check_agent_policy_link "$label" "tooling guidance" "$AGENT_TOOLING_SOURCE" "$root/${agent_tooling_suffixes[$index]}"
      fi
    fi
  done
}
