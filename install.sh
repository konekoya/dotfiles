#!/bin/bash

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
case "$DOTFILES_DIR" in
  *[!A-Za-z0-9_./+@-]*)
    echo "❌ $DOTFILES_DIR contains characters that cannot be written safely to ~/.zshrc." >&2
    echo "   Move the repository to a path without spaces or shell special characters." >&2
    exit 1
    ;;
esac
SKILLS_SOURCE="$DOTFILES_DIR/skills"
LEGACY_SKILLS_SOURCE="$DOTFILES_DIR/claude/skills"
# Skills Claude Code already ships as an official plugin. Linking the
# repository copy there would list the same skill twice, so Claude Code
# skips them; the other tools have no plugin and keep the copy.
CLAUDE_PLUGIN_SKILLS="skill-creator"
source "$DOTFILES_DIR/lib/shell-config.sh" || exit 1
source "$DOTFILES_DIR/lib/agent-policy.sh" || exit 1
source "$DOTFILES_DIR/lib/local-env.sh" || exit 1
source "$DOTFILES_DIR/lib/work-notes.sh" || exit 1
source "$DOTFILES_DIR/lib/morning.sh" || exit 1

install_deps=false
for arg in "$@"; do
  case "$arg" in
    --install-deps) install_deps=true ;;
    -h|--help)
      echo "Usage: ./install.sh [--install-deps]"
      echo "  --install-deps  also install missing Homebrew packages from Brewfile and oh-my-zsh"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: ./install.sh [--install-deps]" >&2
      exit 2
      ;;
  esac
done

echo "🔗 Creating symlinks..."

path_resolves_to() {
  local path="$1"
  local expected="$2"
  local resolved_path
  local resolved_expected

  resolved_path="$(cd -P "$path" 2>/dev/null && pwd -P)" || return 1
  resolved_expected="$(cd -P "$expected" 2>/dev/null && pwd -P)" || return 1
  [ "$resolved_path" = "$resolved_expected" ]
}

symlink_points_to_path() {
  local link="$1"
  local expected="$2"
  local link_target
  local link_parent
  local target_path
  local target_parent
  local expected_parent

  [ -L "$link" ] || return 1
  link_target="$(readlink "$link" 2>/dev/null)" || return 1
  [ "$link_target" = "$expected" ] && return 0
  [ "$link" -ef "$expected" ] && return 0
  path_resolves_to "$link" "$expected" && return 0

  # Also recognize relative legacy links when the final skill directory has
  # already moved but its parent directory still exists.
  link_parent="$(cd -P "$(dirname "$link")" 2>/dev/null && pwd -P)" || return 1
  case "$link_target" in
    /*) target_path="$link_target" ;;
    *) target_path="$link_parent/$link_target" ;;
  esac
  target_parent="$(cd -P "$(dirname "$target_path")" 2>/dev/null && pwd -P)" || return 1
  expected_parent="$(cd -P "$(dirname "$expected")" 2>/dev/null && pwd -P)" || return 1

  [ "$target_parent/$(basename "$target_path")" = "$expected_parent/$(basename "$expected")" ]
}

link_config_file() {
  local source="$1"
  local target="$2"

  if [ -L "$target" ]; then
    if [ -e "$target" ] && symlink_points_to_path "$target" "$source"; then
      echo "🔗 $target already linked to $source, skipping."
    elif [ ! -e "$target" ]; then
      echo "⚠️  $target is a broken symlink; preserving it. Remove it manually to link $source."
    else
      echo "⚠️  $target points elsewhere; preserving it instead of linking $source."
    fi
  elif [ -e "$target" ]; then
    echo "⚠️  $target already exists; preserving it instead of linking $source."
  elif ln -s "$source" "$target"; then
    echo "🔗 Linked $target → $source"
  else
    echo "⚠️  Could not link $target → $source."
  fi
}

link_config_file "$DOTFILES_DIR/git/.gitconfig" "$HOME/.gitconfig"
link_config_file "$DOTFILES_DIR/git/.gitignore_global" "$HOME/.gitignore_global"

# git: create ~/.gitconfig.local from the template if it doesn't exist (per-machine identity)
GIT_LOCAL_FILE="$HOME/.gitconfig.local"
if [ ! -e "$GIT_LOCAL_FILE" ] && [ ! -L "$GIT_LOCAL_FILE" ]; then
  echo "🪪 Creating $GIT_LOCAL_FILE for your Git identity..."
  if (set -C; cat "$DOTFILES_DIR/git/.gitconfig.local.example" > "$GIT_LOCAL_FILE"); then
    echo "   ✓ Created $GIT_LOCAL_FILE — set user.name and user.email in it"
  else
    echo "⚠️  Could not create $GIT_LOCAL_FILE; preserving any existing path."
  fi
else
  echo "🪪 $GIT_LOCAL_FILE already exists, preserving it."
fi

# git: create ~/.gitconfig.work from the template if it doesn't exist (optional work identity)
GIT_WORK_FILE="$HOME/.gitconfig.work"
if [ ! -e "$GIT_WORK_FILE" ] && [ ! -L "$GIT_WORK_FILE" ]; then
  echo "💼 Creating $GIT_WORK_FILE for an optional work Git identity..."
  if (set -C; cat "$DOTFILES_DIR/git/.gitconfig.work.example" > "$GIT_WORK_FILE"); then
    echo "   ✓ Created $GIT_WORK_FILE — used only when the includeIf rules in $GIT_LOCAL_FILE are enabled"
  else
    echo "⚠️  Could not create $GIT_WORK_FILE; preserving any existing path."
  fi
else
  echo "💼 $GIT_WORK_FILE already exists, preserving it."
fi

if mkdir -p "$HOME/.config"; then
  link_config_file "$DOTFILES_DIR/zsh/starship.toml" "$HOME/.config/starship.toml"
else
  echo "⚠️  Could not create $HOME/.config; skipping starship config link."
fi

is_legacy_skills_parent_link() {
  local target_dir="$1"
  symlink_points_to_path "$target_dir" "$LEGACY_SKILLS_SOURCE"
}

prepare_tool_skills_directory() {
  local target_dir="$1"
  local label="$2"

  if [ -L "$target_dir" ]; then
    if is_legacy_skills_parent_link "$target_dir"; then
      if unlink "$target_dir"; then
        echo "🤖 Removed legacy $label skills parent symlink."
      else
        echo "⚠️  Could not remove legacy skills symlink $target_dir; skipping $label skills."
        return 1
      fi
    else
      echo "⚠️  $target_dir points elsewhere, preserving it and skipping $label skills."
      return 1
    fi
  elif [ -e "$target_dir" ] && [ ! -d "$target_dir" ]; then
    echo "⚠️  $target_dir is not a directory, preserving it and skipping $label skills."
    return 1
  fi

  if [ ! -d "$target_dir" ]; then
    if ! mkdir -p "$target_dir"; then
      echo "⚠️  Could not create $target_dir; skipping $label skills."
      return 1
    fi
    echo "🤖 Created $label skills directory $target_dir."
  fi
}

migrate_claude_synced_directory() {
  local legacy_synced="$LEGACY_SKILLS_SOURCE/synced"
  local claude_synced="$HOME/.claude/skills/synced"
  local tool_synced

  for tool_synced in "$HOME/.agents/skills/synced" "$HOME/.kiro/skills/synced"; do
    if symlink_points_to_path "$tool_synced" "$legacy_synced"; then
      if unlink "$tool_synced"; then
        echo "🤖 Removed stale Claude synced link $tool_synced."
      else
        echo "⚠️  Could not remove stale synced link $tool_synced."
      fi
    fi
  done

  if [ ! -e "$legacy_synced" ] && [ ! -L "$legacy_synced" ]; then
    return 0
  fi

  if [ -e "$claude_synced" ] || [ -L "$claude_synced" ]; then
    echo "⚠️  Both $legacy_synced and $claude_synced exist; preserving both without overwriting either."
    return 0
  fi

  if [ -L "$legacy_synced" ] || [ ! -d "$legacy_synced" ]; then
    echo "⚠️  $legacy_synced is not a real directory; preserving it for manual review."
    return 0
  fi

  # Move into the existing real skills directory. -n avoids replacing a
  # destination that appears after the collision check.
  if mv -n "$legacy_synced" "$HOME/.claude/skills/" && \
    [ ! -e "$legacy_synced" ] && [ ! -L "$legacy_synced" ]; then
    echo "🤖 Preserved Claude-managed synced skills at $claude_synced."
  else
    echo "⚠️  Could not move Claude-managed synced skills without overwriting; preserved source at $legacy_synced."
  fi
}

name_is_listed() {
  local name="$1"
  local list="$2"
  local entry

  for entry in $list; do
    [ "$entry" = "$name" ] && return 0
  done

  return 1
}

# Retire only our own link for a skill the tool now provides itself. Custom
# files, directories, and links to other sources are preserved. Returns 0 when
# something was reported.
retire_repository_skill_link() {
  local target_dir="$1"
  local skill_name="$2"
  local label="$3"
  local skill_target="$target_dir/$skill_name"

  symlink_points_to_path "$skill_target" "$SKILLS_SOURCE/$skill_name" || \
    symlink_points_to_path "$skill_target" "$LEGACY_SKILLS_SOURCE/$skill_name" || return 1

  if unlink "$skill_target"; then
    echo "🤖 Removed $label skill link $skill_name; $label provides it as a plugin."
  else
    echo "⚠️  Could not remove $label skill link $skill_target."
  fi
}

# Link only repository-managed skills. Tool-managed entries and real directories
# are left untouched.
link_skills_individually() {
  local target_dir="$1"
  local label="$2"
  local skill_dir
  local skill_name
  local skill_target
  local legacy_skill
  local directory_prepared="${3:-false}"
  local skipped_skills="${4:-}"
  local already_linked=0
  local reported=0

  if [ "$directory_prepared" != true ] && ! prepare_tool_skills_directory "$target_dir" "$label"; then
    return 0
  fi

  for skill_dir in "$SKILLS_SOURCE"/*; do
    [ -d "$skill_dir" ] && [ ! -L "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue

    skill_name="${skill_dir##*/}"
    skill_name="${skill_name%/}"

    if name_is_listed "$skill_name" "$skipped_skills"; then
      if retire_repository_skill_link "$target_dir" "$skill_name" "$label"; then
        reported=$((reported + 1))
      fi
      continue
    fi

    skill_target="$target_dir/$skill_name"

    if [ -L "$skill_target" ]; then
      legacy_skill="$LEGACY_SKILLS_SOURCE/$skill_name"

      if symlink_points_to_path "$skill_target" "$skill_dir"; then
        already_linked=$((already_linked + 1))
      elif symlink_points_to_path "$skill_target" "$legacy_skill"; then
        if unlink "$skill_target" && ln -s "$skill_dir" "$skill_target"; then
          echo "🤖 Updated $label skill $skill_name link to $skill_dir."
          reported=$((reported + 1))
        else
          echo "⚠️  Could not update $label skill link $skill_target."
          reported=$((reported + 1))
        fi
      else
        echo "⚠️  $skill_target points elsewhere, skipping."
        reported=$((reported + 1))
      fi
    elif [ -e "$skill_target" ]; then
      echo "⚠️  $skill_target already exists, skipping."
      reported=$((reported + 1))
    else
      if ln -s "$skill_dir" "$skill_target"; then
        echo "🤖 Linked $label skill $skill_name → $skill_dir"
        reported=$((reported + 1))
      else
        echo "⚠️  Could not link $label skill $skill_name at $skill_target."
        reported=$((reported + 1))
      fi
    fi
  done

  # Retire only our old PR skill link, and only after its replacement is usable.
  # Preserve user-owned directories and links to any other source.
  if [ -f "$SKILLS_SOURCE/create-pr/SKILL.md" ] && \
    symlink_points_to_path "$target_dir/create-pr" "$SKILLS_SOURCE/create-pr"; then
    legacy_skill="$target_dir/create-azure-pr"
    if symlink_points_to_path "$legacy_skill" "$SKILLS_SOURCE/create-azure-pr" || \
      symlink_points_to_path "$legacy_skill" "$LEGACY_SKILLS_SOURCE/create-azure-pr"; then
      if unlink "$legacy_skill"; then
        echo "🤖 Removed renamed $label skill link create-azure-pr; use create-pr."
      else
        echo "⚠️  Could not remove renamed $label skill link $legacy_skill."
      fi
    fi
  fi

  # Per-skill lines are only for changes and problems; summarize the rest.
  if [ "$already_linked" -gt 0 ]; then
    if [ "$reported" -eq 0 ]; then
      echo "🤖 $label: all $already_linked skills already linked."
    else
      echo "🤖 $label: $already_linked other skills already linked."
    fi
  fi
}

if prepare_tool_skills_directory "$HOME/.claude/skills" "Claude Code"; then
  migrate_claude_synced_directory
  link_skills_individually "$HOME/.claude/skills" "Claude Code" true "$CLAUDE_PLUGIN_SKILLS"
fi

link_skills_individually "$HOME/.copilot/skills" "GitHub Copilot CLI"
link_skills_individually "$HOME/.agents/skills" "Codex"
link_skills_individually "$HOME/.kiro/skills" "Kiro CLI"

# Direct native instruction entry points; no edits to existing user instructions.
install_agent_policy

# Homebrew packages: opt-in because installs are slow and change the system.
# brew bundle skips packages that are already installed, so reruns are safe.
BREWFILE="$DOTFILES_DIR/Brewfile"
if $install_deps; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "⚠️  Homebrew not found; skipping dependency install. See https://brew.sh"
  elif [ ! -f "$BREWFILE" ]; then
    echo "⚠️  $BREWFILE is missing; skipping dependency install."
  else
    echo "🍺 Installing missing Homebrew packages from Brewfile..."
    if brew bundle --file "$BREWFILE"; then
      echo "🍺 Homebrew packages are up to date."
    else
      echo "⚠️  brew bundle reported errors; run \`doctor\` to see what is still missing."
    fi
  fi
fi

# oh-my-zsh: also opt-in. Cloned with git instead of the official installer,
# which replaces ~/.zshrc. An existing path is never touched.
OMZ_DIR="$HOME/.oh-my-zsh"
if $install_deps; then
  if [ -e "$OMZ_DIR" ] || [ -L "$OMZ_DIR" ]; then
    echo "🎨 $OMZ_DIR already exists, skipping."
  elif ! command -v git >/dev/null 2>&1; then
    echo "⚠️  git not found; skipping oh-my-zsh install."
  elif git clone --depth 1 "https://github.com/ohmyzsh/ohmyzsh.git" "$OMZ_DIR"; then
    echo "🎨 Cloned oh-my-zsh → $OMZ_DIR"
  else
    echo "⚠️  Could not clone oh-my-zsh into $OMZ_DIR."
  fi
fi

# oh-my-zsh plugins: clone zsh-autosuggestions and zsh-syntax-highlighting
if [ -d "$HOME/.oh-my-zsh" ]; then
  ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  if mkdir -p "$ZSH_CUSTOM_DIR/plugins"; then
    for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
      plugin_target="$ZSH_CUSTOM_DIR/plugins/$plugin"
      if [ -d "$plugin_target" ]; then
        echo "🎨 $plugin already exists, skipping."
      elif [ -e "$plugin_target" ] || [ -L "$plugin_target" ]; then
        echo "⚠️  $plugin_target already exists and is not a directory; preserving it."
      elif git clone "https://github.com/zsh-users/$plugin" "$plugin_target"; then
        echo "🎨 Cloned $plugin → $plugin_target"
      else
        echo "⚠️  Could not clone $plugin into $plugin_target."
      fi
    done
  else
    echo "⚠️  Could not create $ZSH_CUSTOM_DIR/plugins; skipping Oh My Zsh plugins."
  fi

  if ! cat "$HOME/.zshrc" "$DOTFILES_DIR/zsh/.zshrc.shared" 2>/dev/null | grep -q 'zsh-autosuggestions' ||
    ! cat "$HOME/.zshrc" "$DOTFILES_DIR/zsh/.zshrc.shared" 2>/dev/null | grep -q 'zsh-syntax-highlighting'; then
    echo "⚠️  Add zsh-autosuggestions and zsh-syntax-highlighting to plugins=(...) in ~/.zshrc"
  fi
fi

# alias: create .user_alias if it doesn't exist (per-machine custom aliases)
USER_ALIAS="$DOTFILES_DIR/alias/.user_alias"
if [ ! -e "$USER_ALIAS" ] && [ ! -L "$USER_ALIAS" ]; then
  echo "📝 Creating $USER_ALIAS for per-machine custom aliases..."
  if (
    set -C
    cat > "$USER_ALIAS" << 'EOF'
# Per-machine custom aliases
# This file is NOT tracked by git — add your machine-specific aliases here.
# e.g. alias myserver="ssh user@192.168.x.x"
EOF
  ); then
    echo "   ✓ Created $USER_ALIAS"
  else
    echo "⚠️  Could not create $USER_ALIAS; preserving any existing path."
  fi
else
  echo "📝 $USER_ALIAS already exists, preserving it."
fi

# alias: create .env from .env.example if it doesn't exist (per-machine tokens/secrets)
ENV_FILE="$DOTFILES_DIR/alias/.env"
if [ ! -e "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ]; then
  echo "🔑 Creating $ENV_FILE for per-machine tokens..."
  if (umask 077; set -C; cat "$DOTFILES_DIR/alias/.env.example" > "$ENV_FILE"); then
    echo "   ✓ Created $ENV_FILE — fill in tokens as needed (see alias/.env.example for the list)"
  else
    echo "⚠️  Could not create $ENV_FILE; preserving any existing path."
  fi
else
  echo "🔑 $ENV_FILE already exists, preserving it."
fi

# zsh: create .zshrc.local from .zshrc.local.example if it doesn't exist (per-machine zsh overrides)
ZSH_LOCAL_FILE="$DOTFILES_DIR/zsh/.zshrc.local"
if [ ! -e "$ZSH_LOCAL_FILE" ] && [ ! -L "$ZSH_LOCAL_FILE" ]; then
  echo "🐚 Creating $ZSH_LOCAL_FILE for per-machine zsh overrides..."
  if (set -C; cat "$DOTFILES_DIR/zsh/.zshrc.local.example" > "$ZSH_LOCAL_FILE"); then
    echo "   ✓ Created $ZSH_LOCAL_FILE — see zsh/.zshrc.local.example for ideas"
  else
    echo "⚠️  Could not create $ZSH_LOCAL_FILE; preserving any existing path."
  fi
else
  echo "🐚 $ZSH_LOCAL_FILE already exists, preserving it."
fi

# Work notes: optional private repository cloned from WORK_NOTES_REPO in alias/.env.
# Its links.tsv decides what gets linked; existing paths are never replaced.
local_env_load WORK_NOTES_REPO WORK_NOTES_DIR
WORK_NOTES_PATH="$(work_notes_dir)"
if [ ! -e "$WORK_NOTES_PATH" ] && [ ! -L "$WORK_NOTES_PATH" ]; then
  if [ -z "${WORK_NOTES_REPO:-}" ]; then
    echo "📒 Work notes are not configured; set WORK_NOTES_REPO in alias/.env to clone them."
  elif ! command -v git >/dev/null 2>&1; then
    echo "⚠️  git not found; skipping work notes clone."
  # Git output is hidden because it can echo the repository URL.
  elif git clone --quiet -- "$WORK_NOTES_REPO" "$WORK_NOTES_PATH" >/dev/null 2>&1; then
    echo "📒 Cloned work notes → $WORK_NOTES_PATH"
  else
    echo "⚠️  Could not clone work notes into $WORK_NOTES_PATH."
    echo "   Verify WORK_NOTES_REPO points to an existing repository your account can access."
    echo "   Check Git authentication and network connectivity, then rerun ./install.sh."
  fi
fi

if [ -d "$WORK_NOTES_PATH" ]; then
  if [ ! -f "$WORK_NOTES_PATH/links.tsv" ]; then
    echo "📒 $WORK_NOTES_PATH has no links.tsv; nothing to link."
  fi
  while IFS=$'\t' read -r status source target _kind _manifest; do
    if [ "$status" != ok ]; then
      echo "⚠️  Skipping $source: $target"
    elif [ ! -e "$source" ]; then
      echo "⚠️  Work notes path $source does not exist; skipping its link."
    elif [ -d "$target" ] && [ ! -L "$target" ]; then
      echo "⚠️  $target is a real directory; move its files into $source, remove it, and rerun install.sh."
    elif mkdir -p "$(dirname "$target")"; then
      link_config_file "$source" "$target"
    else
      echo "⚠️  Could not create the parent directory of $target."
    fi
  done < <(work_notes_entries "$WORK_NOTES_PATH")
elif [ -e "$WORK_NOTES_PATH" ]; then
  echo "⚠️  $WORK_NOTES_PATH is not a directory; preserving it and skipping work notes links."
fi

# morning: repositories to sync at the start of the day, from MORNING_REPOS in alias/.env.
local_env_load MORNING_REPOS
morning_configured=false
while IFS= read -r morning_path; do
  morning_configured=true
  morning_problem="$(morning_repo_problem "$morning_path")"
  if [ -n "$morning_problem" ]; then
    echo "⚠️  morning repository $morning_path $morning_problem; fix MORNING_REPOS in alias/.env."
  fi
done < <(morning_repo_paths)
if [ "$morning_configured" = false ]; then
  echo "⚠️  morning has no repositories to sync; set MORNING_REPOS in alias/.env (colon-separated paths)."
fi

ZSHRC="$HOME/.zshrc"
added_anything=false

if [ -L "$ZSHRC" ] && [ ! -e "$ZSHRC" ]; then
  echo "⚠️  $ZSHRC is a broken symlink; preserving it and skipping shell config updates."
elif [ -e "$ZSHRC" ] && [ ! -f "$ZSHRC" ]; then
  echo "⚠️  $ZSHRC is not a regular file; preserving it and skipping shell config updates."
elif touch "$ZSHRC"; then
  if ! shell_config_has_setting "$ZSHRC" aliases; then
    if { printf '\n' >> "$ZSHRC" && printf '%s\n' "source $(shell_config_ref "$DOTFILES_DIR/alias/.alias" tilde)" >> "$ZSHRC"; }; then
      echo "🐚 Added alias source to ~/.zshrc"
      added_anything=true
    else
      echo "⚠️  Could not add alias source to ~/.zshrc."
    fi
  else
    echo "🐚 Alias source already in ~/.zshrc, skipping."
  fi

  if ! shell_config_has_setting "$ZSHRC" shared; then
    if printf '%s\n' "source $(shell_config_ref "$DOTFILES_DIR/zsh/.zshrc.shared" tilde)" >> "$ZSHRC"; then
      echo "🐚 Added shared zsh config source to ~/.zshrc"
      added_anything=true
    else
      echo "⚠️  Could not add shared zsh config source to ~/.zshrc."
    fi
  else
    echo "🐚 Shared zsh config source already in ~/.zshrc, skipping."
  fi

  if ! shell_config_has_setting "$ZSHRC" path; then
    if printf '%s\n' "export PATH=\"$(shell_config_ref "$DOTFILES_DIR/scripts" home):\$PATH\"" >> "$ZSHRC"; then
      echo "🐚 Added dotfiles/scripts to PATH in ~/.zshrc"
      added_anything=true
    else
      echo "⚠️  Could not add dotfiles/scripts to PATH in ~/.zshrc."
    fi
  else
    echo "🐚 Scripts PATH already in ~/.zshrc, skipping."
  fi
else
  echo "⚠️  Could not create or access ~/.zshrc; skipping shell config updates."
fi

echo "✅ Installer configuration pass finished."
if $added_anything; then
  echo ""
  echo "⚠️  Run: source ~/.zshrc  (to apply changes in this session)"
fi

echo "Run \`doctor\` to verify the setup and optional dependencies."
if ! $install_deps; then
  echo "Tip: run \`./install.sh --install-deps\` to install missing tools (delta, fzf, jq, gh, starship, ...) with Homebrew and oh-my-zsh."
fi
