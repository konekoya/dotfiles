#!/bin/bash
# Description: Regression coverage for installer preservation and success reporting
# shellcheck disable=SC2088 # "~/..." in messages is literal text, not a path to expand

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REAL_BASH="$(command -v bash)"
# Agent profiles must never escape the temporary HOME through inherited overrides.
unset CODEX_HOME CLAUDE_CONFIG_DIR COPILOT_HOME
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/install-regression.XXXXXX")" || exit 1
# Scripts report their location through pwd, so use the same normalized path in expectations.
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)" || exit 1

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

setup_fixture() {
  local name="$1"
  TEST_CASE_DIR="$TEST_ROOT/$name"
  TEST_HOME="$TEST_CASE_DIR/home"
  TEST_DOTFILES="$TEST_HOME/dotfiles"
  mkdir -p "$TEST_DOTFILES/git" "$TEST_DOTFILES/alias" "$TEST_DOTFILES/lib" "$TEST_DOTFILES/zsh" "$TEST_DOTFILES/scripts" "$TEST_DOTFILES/skills/sample-skill" || fail "could not create fixture for $name"
  cp "$REPO_ROOT/lib/agent-policy.sh" "$TEST_DOTFILES/lib/" || fail "could not copy agent policy helper"
  mkdir -p "$TEST_DOTFILES/agents" || fail "could not create policy directory"
  cp "$REPO_ROOT/agents/security.md" "$TEST_DOTFILES/agents/" || fail "could not copy policy"
  cp "$REPO_ROOT/lib/shell-config.sh" "$TEST_DOTFILES/lib/" || fail "could not copy shell helpers"
  cp "$REPO_ROOT/scripts/doctor" "$TEST_DOTFILES/scripts/doctor" || fail "could not copy doctor for $name"
  cp "$REPO_ROOT/install.sh" "$TEST_DOTFILES/install.sh" || fail "could not copy installer for $name"
  cp "$REPO_ROOT/git/.gitconfig" "$TEST_DOTFILES/git/.gitconfig" || fail "could not copy Git config for $name"
  cp "$REPO_ROOT/git/.gitignore_global" "$REPO_ROOT/git/.gitconfig.local.example" "$REPO_ROOT/git/.gitconfig.work.example" "$TEST_DOTFILES/git/" || fail "could not copy Git support files for $name"
  cp "$REPO_ROOT/zsh/.zshrc.shared" "$REPO_ROOT/zsh/.zshrc.local.example" "$REPO_ROOT/zsh/starship.toml" "$TEST_DOTFILES/zsh/" || fail "could not copy zsh config for $name"
  printf '# sample environment\n' > "$TEST_DOTFILES/alias/.env.example"
  printf '# sample skill\n' > "$TEST_DOTFILES/skills/sample-skill/SKILL.md"
}

run_installer() {
  HOME="$TEST_HOME" \
    ZSH_CUSTOM="$TEST_HOME/.oh-my-zsh/custom" \
    PATH="${INSTALL_TEST_PATH:-$PATH}" \
    "$REAL_BASH" "$TEST_DOTFILES/install.sh" "$@"
}

assert_link_target() {
  local link="$1"
  local expected="$2"
  [ -L "$link" ] || fail "$link is not a symlink"
  [ "$(readlink "$link")" = "$expected" ] || fail "$link points somewhere unexpected"
}

# Missing Git config targets are linked, and a second run leaves the setup idempotent.
setup_fixture missing-and-idempotent
run_installer > "$TEST_CASE_DIR/first-output" 2>&1 || fail "installer failed on missing targets"
assert_link_target "$TEST_HOME/.gitconfig" "$TEST_DOTFILES/git/.gitconfig"
assert_link_target "$TEST_HOME/.gitignore_global" "$TEST_DOTFILES/git/.gitignore_global"
for entry in .codex/AGENTS.md .claude/rules/dotfiles-security.md .kiro/steering/dotfiles-security.md .copilot/copilot-instructions.md; do
  assert_link_target "$TEST_HOME/$entry" "$TEST_DOTFILES/agents/security.md"
done
grep -Fq 'Linked ' "$TEST_CASE_DIR/first-output" || fail "missing Git config targets were not reported as linked"
grep -Fq 'Run `doctor` to verify' "$TEST_CASE_DIR/first-output" || fail "installer did not recommend doctor"
run_installer > "$TEST_CASE_DIR/second-output" 2>&1 || fail "installer failed on its second run"
grep -Fq "$TEST_HOME/.gitconfig already linked" "$TEST_CASE_DIR/second-output" || fail "correct .gitconfig link was not recognized"
grep -Fq "$TEST_HOME/.gitignore_global already linked" "$TEST_CASE_DIR/second-output" || fail "correct .gitignore_global link was not recognized"
[ "$(grep -c 'security policy already linked' "$TEST_CASE_DIR/second-output")" -eq 4 ] || fail "global policy links were not idempotent"
[ "$(grep -Fxc 'source ~/dotfiles/alias/.alias' "$TEST_HOME/.zshrc")" -eq 1 ] || fail "repeated runs duplicated the alias source"
[ "$(grep -Fxc 'export PATH="$HOME/dotfiles/scripts:$PATH"' "$TEST_HOME/.zshrc")" -eq 1 ] || fail "repeated runs duplicated the scripts PATH"
[ "$(stat -f '%Lp' "$TEST_DOTFILES/alias/.env")" = 600 ] || fail "new environment file is not private"
assert_link_target "$TEST_HOME/.config/starship.toml" "$TEST_DOTFILES/zsh/starship.toml"
[ "$(grep -Fxc 'source ~/dotfiles/zsh/.zshrc.shared' "$TEST_HOME/.zshrc")" -eq 1 ] || fail "repeated runs duplicated the shared zsh source"
cmp -s "$TEST_DOTFILES/zsh/.zshrc.local.example" "$TEST_DOTFILES/zsh/.zshrc.local" || fail "zsh/.zshrc.local was not created from the example"
grep -Fq "$TEST_DOTFILES/zsh/.zshrc.local already exists" "$TEST_CASE_DIR/second-output" || fail "existing .zshrc.local was not recognized"

# Git identity lives in ~/.gitconfig.local: created from the template once, never overwritten.
grep -Fq 'name = Your Name' "$TEST_HOME/.gitconfig.local" || fail "~/.gitconfig.local was not created from the template"
grep -Fq 'Created' "$TEST_CASE_DIR/first-output" || fail "creating ~/.gitconfig.local was not reported"
grep -Fq "$TEST_HOME/.gitconfig.local already exists" "$TEST_CASE_DIR/second-output" || fail "existing ~/.gitconfig.local was not recognized"
setup_fixture git-local-preserved
printf '[user]\n\tname = Kept\n' > "$TEST_HOME/.gitconfig.local"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed with an existing ~/.gitconfig.local"
[ "$(cat "$TEST_HOME/.gitconfig.local")" = "$(printf '[user]\n\tname = Kept')" ] || fail "existing ~/.gitconfig.local was changed"
HOME="$TEST_HOME" git config --global --includes --get user.name | grep -Fxq Kept || fail "shared Git config did not include ~/.gitconfig.local"

# Work identity: ~/.gitconfig.work is created once, and the example includeIf rules pick it by remote URL.
cmp -s "$TEST_DOTFILES/git/.gitconfig.work.example" "$TEST_HOME/.gitconfig.work" || fail "~/.gitconfig.work was not created from the template"
setup_fixture git-work-identity
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed before the work identity check"
sed -E -e '/^# (\[includeIf |\tpath)/s/^# //' -e 's/^\t# (name|email) = .*/\t\1 = personal/' -e 's/work-org/org/g' "$TEST_DOTFILES/git/.gitconfig.local.example" > "$TEST_HOME/.gitconfig.local" || fail "could not enable the example includeIf rules"
printf '[user]\n\temail = work@example.com\n' > "$TEST_HOME/.gitconfig.work"
for remote_case in \
  'git@github.com:me/repo.git:personal' \
  'https://github.com/me/repo.git:personal' \
  'https://dev.azure.com/org/project/_git/repo:work@example.com' \
  'https://org@dev.azure.com/org/project/_git/repo:work@example.com' \
  'git@ssh.dev.azure.com:v3/org/project/repo:work@example.com' \
  'ssh://ssh.dev.azure.com/v3/org/project/repo:work@example.com' \
  'ssh://git@ssh.dev.azure.com/v3/org/project/repo:work@example.com' \
  'https://org.visualstudio.com/project/_git/repo:work@example.com'; do
  remote_url="${remote_case%:*}"
  expected_email="${remote_case##*:}"
  rm -rf "$TEST_CASE_DIR/repo"
  git init -q "$TEST_CASE_DIR/repo" || fail "could not create test repository"
  git -C "$TEST_CASE_DIR/repo" remote add origin "$remote_url" || fail "could not add remote $remote_url"
  [ "$(HOME="$TEST_HOME" git -C "$TEST_CASE_DIR/repo" config user.email)" = "$expected_email" ] || fail "remote $remote_url did not select $expected_email"
done

# Skill output stays quiet: one summary per tool when all are linked, per-skill lines only for new links.
setup_fixture skill-link-summary
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "first skill install failed"
grep -Fq 'Linked Claude Code skill sample-skill' "$TEST_CASE_DIR/output" || fail "new skill link was not reported"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "second skill install failed"
grep -Fq 'Claude Code: all 1 skills already linked.' "$TEST_CASE_DIR/output" || fail "linked skills were not summarized for Claude Code"
grep -Fq 'Kiro CLI: all 1 skills already linked.' "$TEST_CASE_DIR/output" || fail "linked skills were not summarized for Kiro CLI"
if grep -Fq 'skill sample-skill' "$TEST_CASE_DIR/output"; then
  fail "already linked skills were still listed one by one"
fi
mkdir -p "$TEST_DOTFILES/skills/second-skill" || fail "could not add second skill"
printf '# second skill\n' > "$TEST_DOTFILES/skills/second-skill/SKILL.md"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "install with a new skill failed"
grep -Fq 'Linked Claude Code skill second-skill' "$TEST_CASE_DIR/output" || fail "new skill was not reported"
grep -Fq 'Claude Code: 1 other skills already linked.' "$TEST_CASE_DIR/output" || fail "remaining skills were not summarized next to a new link"
if grep -Fq 'skill sample-skill' "$TEST_CASE_DIR/output"; then
  fail "unchanged skill was listed next to a new link"
fi

# A renamed PR skill retires only installer-owned old links, including broken
# relative/legacy links, after linking its replacement. Repeated runs are safe.
for link_style in absolute relative legacy chained; do
  setup_fixture "renamed-pr-skill-$link_style"
  mkdir -p "$TEST_DOTFILES/skills/create-pr" "$TEST_DOTFILES/claude/skills" || fail "could not prepare renamed skill"
  printf '# PR skill\n' > "$TEST_DOTFILES/skills/create-pr/SKILL.md"
  ln -s "$TEST_DOTFILES/skills" "$TEST_CASE_DIR/source-skills" || fail "could not prepare chained source"
  for tool in .claude .copilot .agents .kiro; do
    mkdir -p "$TEST_HOME/$tool/skills" || fail "could not prepare tool skills"
    case "$link_style" in
      absolute) link_target="$TEST_DOTFILES/skills/create-azure-pr" ;;
      relative) link_target="../../dotfiles/skills/create-azure-pr" ;;
      legacy) link_target="../../dotfiles/claude/skills/create-azure-pr" ;;
      chained) link_target="$TEST_CASE_DIR/source-skills/create-azure-pr" ;;
    esac
    ln -s "$link_target" "$TEST_HOME/$tool/skills/create-azure-pr" || fail "could not prepare old PR skill link"
  done
  run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "renamed skill migration failed"
  run_installer >> "$TEST_CASE_DIR/output" 2>&1 || fail "repeated renamed skill migration failed"
  for tool in .claude .copilot .agents .kiro; do
    assert_link_target "$TEST_HOME/$tool/skills/create-pr" "$TEST_DOTFILES/skills/create-pr"
    [ ! -e "$TEST_HOME/$tool/skills/create-azure-pr" ] && \
      [ ! -L "$TEST_HOME/$tool/skills/create-azure-pr" ] || fail "old installer-owned PR skill link remains"
  done
done

# User-owned old skills survive, and a conflicting replacement prevents cleanup.
setup_fixture renamed-pr-skill-conflicts
mkdir -p "$TEST_DOTFILES/skills/create-pr" "$TEST_CASE_DIR/custom-skill" || fail "could not prepare conflict sources"
printf '# PR skill\n' > "$TEST_DOTFILES/skills/create-pr/SKILL.md"
for tool in .claude .copilot .agents .kiro; do
  mkdir -p "$TEST_HOME/$tool/skills" || fail "could not prepare conflict destinations"
done
mkdir -p "$TEST_HOME/.claude/skills/create-azure-pr" || fail "could not prepare custom old directory"
printf 'custom skill\n' > "$TEST_HOME/.claude/skills/create-azure-pr/SKILL.md"
ln -s "$TEST_CASE_DIR/custom-skill" "$TEST_HOME/.copilot/skills/create-azure-pr" || fail "could not prepare custom old link"
printf 'custom replacement\n' > "$TEST_HOME/.agents/skills/create-pr"
ln -s "$TEST_CASE_DIR/missing-custom-skill" "$TEST_HOME/.kiro/skills/create-pr" || fail "could not prepare broken custom replacement"
for tool in .agents .kiro; do
  ln -s "$TEST_DOTFILES/skills/create-azure-pr" "$TEST_HOME/$tool/skills/create-azure-pr" || fail "could not prepare blocked old link"
done
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "renamed skill conflicts failed"
run_installer >> "$TEST_CASE_DIR/output" 2>&1 || fail "repeated renamed skill conflicts failed"
[ "$(cat "$TEST_HOME/.claude/skills/create-azure-pr/SKILL.md")" = 'custom skill' ] || fail "custom old directory changed"
assert_link_target "$TEST_HOME/.copilot/skills/create-azure-pr" "$TEST_CASE_DIR/custom-skill"
for tool in .claude .copilot; do
  assert_link_target "$TEST_HOME/$tool/skills/create-pr" "$TEST_DOTFILES/skills/create-pr"
done
[ "$(cat "$TEST_HOME/.agents/skills/create-pr")" = 'custom replacement' ] || fail "custom replacement file changed"
assert_link_target "$TEST_HOME/.kiro/skills/create-pr" "$TEST_CASE_DIR/missing-custom-skill"
for tool in .agents .kiro; do
  assert_link_target "$TEST_HOME/$tool/skills/create-azure-pr" "$TEST_DOTFILES/skills/create-azure-pr"
done

# skill-creator ships with a Claude Code plugin: it is linked for the other
# tools only, and an existing installer-owned Claude link is retired. Custom
# Claude entries survive.
setup_fixture claude-plugin-skill
mkdir -p "$TEST_DOTFILES/skills/skill-creator" || fail "could not prepare plugin skill"
printf '# skill creator\n' > "$TEST_DOTFILES/skills/skill-creator/SKILL.md"
mkdir -p "$TEST_HOME/.claude/skills" || fail "could not prepare Claude skills"
ln -s "$TEST_DOTFILES/skills/skill-creator" "$TEST_HOME/.claude/skills/skill-creator" || fail "could not prepare old Claude link"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "plugin skill install failed"
grep -Fq 'Removed Claude Code skill link skill-creator' "$TEST_CASE_DIR/output" || fail "retiring the duplicate Claude link was not reported"
[ ! -e "$TEST_HOME/.claude/skills/skill-creator" ] && [ ! -L "$TEST_HOME/.claude/skills/skill-creator" ] || fail "duplicate Claude skill-creator link remains"
for tool in .copilot .agents .kiro; do
  assert_link_target "$TEST_HOME/$tool/skills/skill-creator" "$TEST_DOTFILES/skills/skill-creator"
done
run_installer > "$TEST_CASE_DIR/second-output" 2>&1 || fail "repeated plugin skill install failed"
[ ! -L "$TEST_HOME/.claude/skills/skill-creator" ] || fail "the duplicate Claude link came back"
grep -Fq 'skill-creator' "$TEST_CASE_DIR/second-output" && fail "an unchanged plugin skill was still reported"
grep -Fq 'Claude Code: all 1 skills already linked.' "$TEST_CASE_DIR/second-output" || fail "skipped skill was counted for Claude Code"
grep -Fq 'Kiro CLI: all 2 skills already linked.' "$TEST_CASE_DIR/second-output" || fail "skipped skill was not linked for Kiro CLI"

setup_fixture claude-plugin-skill-custom
mkdir -p "$TEST_DOTFILES/skills/skill-creator" "$TEST_CASE_DIR/custom-skill" || fail "could not prepare custom plugin skill"
printf '# skill creator\n' > "$TEST_DOTFILES/skills/skill-creator/SKILL.md"
mkdir -p "$TEST_HOME/.claude/skills" "$TEST_HOME/.copilot/skills/skill-creator" || fail "could not prepare custom destinations"
ln -s "$TEST_CASE_DIR/custom-skill" "$TEST_HOME/.claude/skills/skill-creator" || fail "could not prepare custom Claude link"
printf 'custom skill\n' > "$TEST_HOME/.copilot/skills/skill-creator/SKILL.md"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "custom plugin skill install failed"
assert_link_target "$TEST_HOME/.claude/skills/skill-creator" "$TEST_CASE_DIR/custom-skill"
[ "$(cat "$TEST_HOME/.copilot/skills/skill-creator/SKILL.md")" = 'custom skill' ] || fail "custom Copilot skill directory changed"

# Commented settings and echo commands must not suppress active shell setup.
setup_fixture commented-shell-settings
cat > "$TEST_HOME/.zshrc" <<'EOF'
# source ~/dotfiles/alias/.alias
# export PATH="$HOME/dotfiles/scripts:$PATH"
echo 'source ~/dotfiles/alias/.alias'
echo 'dotfiles/scripts'
EOF
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed with commented settings"
run_installer >> "$TEST_CASE_DIR/output" 2>&1 || fail "second commented-settings install failed"
[ "$(grep -Fxc 'source ~/dotfiles/alias/.alias' "$TEST_HOME/.zshrc")" -eq 1 ] || fail "active alias source was not added exactly once"
[ "$(grep -Fxc 'export PATH="$HOME/dotfiles/scripts:$PATH"' "$TEST_HOME/.zshrc")" -eq 1 ] || fail "active PATH was not added exactly once"

# Legacy parents become real directories; synced runtime data survives both runs.
setup_fixture legacy-skill-migration
mkdir -p "$TEST_DOTFILES/claude/skills/synced" || fail "could not prepare legacy skills"
printf 'runtime marker\n' > "$TEST_DOTFILES/claude/skills/synced/marker"
for tool in .claude .copilot .agents .kiro; do
  mkdir -p "$TEST_HOME/$tool" || fail "could not create tool parent"
  ln -s ../dotfiles/claude/skills "$TEST_HOME/$tool/skills" || fail "could not link legacy parent"
done
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "legacy migration failed"
run_installer >> "$TEST_CASE_DIR/output" 2>&1 || fail "repeated legacy migration failed"
for tool in .claude .copilot .agents .kiro; do
  [ -d "$TEST_HOME/$tool/skills" ] && [ ! -L "$TEST_HOME/$tool/skills" ] || fail "legacy parent was not replaced"
  assert_link_target "$TEST_HOME/$tool/skills/sample-skill" "$TEST_DOTFILES/skills/sample-skill"
done
[ "$(cat "$TEST_HOME/.claude/skills/synced/marker")" = 'runtime marker' ] || fail "runtime data was lost"
[ ! -e "$TEST_DOTFILES/claude/skills/synced" ] || fail "legacy runtime data was not moved"

# Existing runtime directories on both sides are preserved without merging.
setup_fixture synced-collision
mkdir -p "$TEST_DOTFILES/claude/skills/synced" "$TEST_HOME/.claude/skills/synced" "$TEST_HOME/.agents/skills" || fail "could not prepare collision"
printf 'legacy\n' > "$TEST_DOTFILES/claude/skills/synced/marker"
printf 'current\n' > "$TEST_HOME/.claude/skills/synced/marker"
ln -s "$TEST_DOTFILES/claude/skills/synced" "$TEST_HOME/.agents/skills/synced" || fail "could not prepare stale synced link"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "synced collision install failed"
[ "$(cat "$TEST_DOTFILES/claude/skills/synced/marker")" = legacy ] || fail "legacy collision data was lost"
[ "$(cat "$TEST_HOME/.claude/skills/synced/marker")" = current ] || fail "current collision data was lost"
[ ! -L "$TEST_HOME/.agents/skills/synced" ] || fail "stale synced link was not removed"

# Unexpected user paths remain untouched, including broken links and skill files.
setup_fixture conflicting-user-paths
for file in .env .user_alias; do
  ln -s "$TEST_CASE_DIR/missing-$file" "$TEST_DOTFILES/alias/$file" || fail "could not create broken user link"
done
ln -s "$TEST_CASE_DIR/missing-zshrc" "$TEST_HOME/.zshrc" || fail "could not create broken shell link"
mkdir -p "$TEST_HOME/.agents" || fail "could not create skills parent"
printf 'user file\n' > "$TEST_HOME/.agents/skills"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "conflicting paths install failed"
for file in .env .user_alias; do
  assert_link_target "$TEST_DOTFILES/alias/$file" "$TEST_CASE_DIR/missing-$file"
  [ ! -e "$TEST_CASE_DIR/missing-$file" ] || fail "broken link target was created"
done
assert_link_target "$TEST_HOME/.zshrc" "$TEST_CASE_DIR/missing-zshrc"
[ ! -e "$TEST_CASE_DIR/missing-zshrc" ] || fail "broken shell link target was created"
[ "$(cat "$TEST_HOME/.agents/skills")" = 'user file' ] || fail "conflicting skills file was changed"

# Correct pre-existing links are left in place.
setup_fixture correct-links
ln -s "$TEST_DOTFILES/git/.gitconfig" "$TEST_HOME/.gitconfig" || fail "could not create correct Git config link"
ln -s "$TEST_DOTFILES/git/.gitignore_global" "$TEST_HOME/.gitignore_global" || fail "could not create correct global gitignore link"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed with correct links"
assert_link_target "$TEST_HOME/.gitconfig" "$TEST_DOTFILES/git/.gitconfig"
assert_link_target "$TEST_HOME/.gitignore_global" "$TEST_DOTFILES/git/.gitignore_global"
grep -Fq "$TEST_HOME/.gitconfig already linked" "$TEST_CASE_DIR/output" || fail "correct .gitconfig link was not reported as already linked"
grep -Fq "$TEST_HOME/.gitignore_global already linked" "$TEST_CASE_DIR/output" || fail "correct .gitignore_global link was not reported as already linked"

# Relative links and links through another symlink are accepted by both tools.
for link_style in relative chained; do
  setup_fixture "$link_style-git-links"
  for target_name in .gitconfig .gitignore_global; do
    if [ "$link_style" = relative ]; then
      link_target="dotfiles/git/$target_name"
    else
      mkdir -p "$TEST_DOTFILES/linked-git" || fail "could not prepare chained links"
      ln -s "../git/$target_name" "$TEST_DOTFILES/linked-git/$target_name" || fail "could not create intermediate $target_name link"
      link_target="dotfiles/linked-git/$target_name"
    fi
    ln -s "$link_target" "$TEST_HOME/$target_name" || fail "could not create $link_style $target_name link"
  done
  run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed with $link_style links"
  for target_name in .gitconfig .gitignore_global; do
    if [ "$link_style" = relative ]; then
      link_target="dotfiles/git/$target_name"
    else
      link_target="dotfiles/linked-git/$target_name"
    fi
    assert_link_target "$TEST_HOME/$target_name" "$link_target"
    grep -Fq "$TEST_HOME/$target_name already linked" "$TEST_CASE_DIR/output" || fail "installer did not recognize $link_style $target_name link"
  done
  HOME="$TEST_HOME" PATH="$TEST_DOTFILES/scripts:$PATH" \
    "$REAL_BASH" "$TEST_DOTFILES/scripts/doctor" > "$TEST_CASE_DIR/doctor-output" 2>&1 || fail "doctor rejected installer-approved $link_style links"
done

# Existing regular files are preserved for both Git config targets.
setup_fixture regular-files
printf 'user gitconfig\n' > "$TEST_HOME/.gitconfig"
printf 'user gitignore\n' > "$TEST_HOME/.gitignore_global"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed with existing regular files"
[ ! -L "$TEST_HOME/.gitconfig" ] && [ "$(cat "$TEST_HOME/.gitconfig")" = 'user gitconfig' ] || fail "existing .gitconfig was changed"
[ ! -L "$TEST_HOME/.gitignore_global" ] && [ "$(cat "$TEST_HOME/.gitignore_global")" = 'user gitignore' ] || fail "existing .gitignore_global was changed"
grep -Fq "$TEST_HOME/.gitconfig already exists; preserving it" "$TEST_CASE_DIR/output" || fail "existing .gitconfig was not reported as preserved"
grep -Fq "$TEST_HOME/.gitignore_global already exists; preserving it" "$TEST_CASE_DIR/output" || fail "existing .gitignore_global was not reported as preserved"

# Unrelated symlinks and broken symlinks are preserved for both targets.
setup_fixture unrelated-links
printf 'unrelated target\n' > "$TEST_CASE_DIR/unrelated-target"
ln -s "$TEST_CASE_DIR/unrelated-target" "$TEST_HOME/.gitconfig" || fail "could not create unrelated .gitconfig link"
ln -s "$TEST_CASE_DIR/missing-target" "$TEST_HOME/.gitignore_global" || fail "could not create broken .gitignore_global link"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed with unrelated symlinks"
assert_link_target "$TEST_HOME/.gitconfig" "$TEST_CASE_DIR/unrelated-target"
assert_link_target "$TEST_HOME/.gitignore_global" "$TEST_CASE_DIR/missing-target"
[ "$(cat "$TEST_CASE_DIR/unrelated-target")" = 'unrelated target' ] || fail "unrelated symlink target was changed"
grep -Fq "$TEST_HOME/.gitconfig points elsewhere; preserving it" "$TEST_CASE_DIR/output" || fail "unrelated .gitconfig link was not reported as preserved"
grep -Fq "$TEST_HOME/.gitignore_global is a broken symlink; preserving it" "$TEST_CASE_DIR/output" || fail "broken .gitignore_global link was not reported as preserved"

# Existing user alias, environment, and shell config files are preserved while shell setup is appended.
setup_fixture user-files
printf 'alias personal=\"true\"\n' > "$TEST_DOTFILES/alias/.user_alias"
printf 'CLICKUP_API_TOKEN=personal-secret\n' > "$TEST_DOTFILES/alias/.env"
printf '# existing shell setup\n' > "$TEST_HOME/.zshrc"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed with existing user files"
[ "$(cat "$TEST_DOTFILES/alias/.user_alias")" = 'alias personal="true"' ] || fail "existing .user_alias was changed"
[ "$(cat "$TEST_DOTFILES/alias/.env")" = 'CLICKUP_API_TOKEN=personal-secret' ] || fail "existing .env was changed"
grep -Fq '# existing shell setup' "$TEST_HOME/.zshrc" || fail "existing .zshrc content was overwritten"

# Existing local zsh overrides and an existing starship config are preserved.
setup_fixture zsh-local-files
mkdir -p "$TEST_HOME/.config" || fail "could not create config directory"
printf 'export LOCAL_ONLY=1\n' > "$TEST_DOTFILES/zsh/.zshrc.local"
printf '# my prompt\n' > "$TEST_HOME/.config/starship.toml"
printf 'source ~/dotfiles/zsh/.zshrc.shared\n' > "$TEST_HOME/.zshrc"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed with existing zsh local files"
[ "$(cat "$TEST_DOTFILES/zsh/.zshrc.local")" = 'export LOCAL_ONLY=1' ] || fail "existing .zshrc.local was changed"
[ ! -L "$TEST_HOME/.config/starship.toml" ] && [ "$(cat "$TEST_HOME/.config/starship.toml")" = '# my prompt' ] || fail "existing starship config was replaced"
grep -Fq "$TEST_HOME/.config/starship.toml already exists; preserving it" "$TEST_CASE_DIR/output" || fail "existing starship config was not reported as preserved"
[ "$(grep -Fxc 'source ~/dotfiles/zsh/.zshrc.shared' "$TEST_HOME/.zshrc")" -eq 1 ] || fail "existing shared zsh source was duplicated"

# A commented shared source does not count as active.
setup_fixture zsh-shared-commented
printf '# source ~/dotfiles/zsh/.zshrc.shared\n' > "$TEST_HOME/.zshrc"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed with commented shared source"
[ "$(grep -Fxc 'source ~/dotfiles/zsh/.zshrc.shared' "$TEST_HOME/.zshrc")" -eq 1 ] || fail "active shared source was not added next to the comment"

# Homebrew dependencies are opt-in: a hint without the flag, brew bundle with it, and failures never stop the installer.
setup_fixture brew-dependencies
cp "$REPO_ROOT/Brewfile" "$TEST_DOTFILES/Brewfile" || fail "could not copy Brewfile"
mkdir -p "$TEST_CASE_DIR/brew-bin" || fail "could not create brew shim directory"
cat > "$TEST_CASE_DIR/brew-bin/brew" <<'EOF'
#!/bin/bash
echo "$*" >> "$BREW_LOG"
[ "$1" = bundle ] || exit 0
[ "$2" = check ] && exit 1
[ -z "$BREW_BUNDLE_FAIL" ]
EOF
chmod +x "$TEST_CASE_DIR/brew-bin/brew" || fail "could not make brew shim executable"
# Git shim: fake clones create the target directory instead of using the network.
mkdir -p "$TEST_CASE_DIR/git-bin" || fail "could not create git shim directory"
cat > "$TEST_CASE_DIR/git-bin/git" <<'EOF'
#!/bin/bash
echo "git $*" >> "$BREW_LOG"
[ "$1" = clone ] || exit 0
[ -z "$GIT_CLONE_FAIL" ] || exit 1
mkdir -p "${@: -1}"
EOF
chmod +x "$TEST_CASE_DIR/git-bin/git" || fail "could not make git shim executable"
export BREW_LOG="$TEST_CASE_DIR/brew.log"
INSTALL_TEST_PATH="$TEST_CASE_DIR/brew-bin:$TEST_CASE_DIR/git-bin:$PATH"
export INSTALL_TEST_PATH

run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed without --install-deps"
grep -Fq './install.sh --install-deps' "$TEST_CASE_DIR/output" || fail "--install-deps was not advertised"
[ ! -e "$BREW_LOG" ] || fail "brew ran without --install-deps"

run_installer --install-deps > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed with --install-deps"
if grep -Fq -- '--install-deps' "$TEST_CASE_DIR/output"; then
  fail "--install-deps tip was shown although the flag was used"
fi
grep -Fxq "bundle --file $TEST_DOTFILES/Brewfile" "$BREW_LOG" || fail "--install-deps did not run brew bundle on the Brewfile"
grep -Fq 'Homebrew packages are up to date' "$TEST_CASE_DIR/output" || fail "successful bundle was not reported"
grep -Fxq "git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git $TEST_HOME/.oh-my-zsh" "$BREW_LOG" || fail "--install-deps did not clone oh-my-zsh"
[ -d "$TEST_HOME/.oh-my-zsh" ] || fail "oh-my-zsh directory was not created"
grep -Fq "Cloned zsh-autosuggestions" "$TEST_CASE_DIR/output" || fail "plugins were not cloned right after oh-my-zsh was installed"

BREW_BUNDLE_FAIL=1 run_installer --install-deps > "$TEST_CASE_DIR/output" 2>&1 || fail "brew bundle failure stopped the installer"
grep -Fq 'brew bundle reported errors' "$TEST_CASE_DIR/output" || fail "brew bundle failure was not reported"
if grep -Fq 'Homebrew packages are up to date' "$TEST_CASE_DIR/output"; then
  fail "failed bundle produced a success message"
fi
grep -Fq 'Run `doctor` to verify' "$TEST_CASE_DIR/output" || fail "installer did not continue after brew bundle failure"

# A second run finds oh-my-zsh and leaves it alone.
: > "$BREW_LOG"
run_installer --install-deps > "$TEST_CASE_DIR/output" 2>&1 || fail "rerun with existing oh-my-zsh failed"
grep -Fq "$TEST_HOME/.oh-my-zsh already exists" "$TEST_CASE_DIR/output" || fail "existing oh-my-zsh was not recognized"
if grep -Fq 'ohmyzsh' "$BREW_LOG"; then
  fail "existing oh-my-zsh was cloned again"
fi

# A failed oh-my-zsh clone is reported and the installer continues.
rm -rf "$TEST_HOME/.oh-my-zsh"
GIT_CLONE_FAIL=1 run_installer --install-deps > "$TEST_CASE_DIR/output" 2>&1 || fail "oh-my-zsh clone failure stopped the installer"
grep -Fq 'Could not clone oh-my-zsh' "$TEST_CASE_DIR/output" || fail "failed oh-my-zsh clone was not reported"
if grep -Fq 'Cloned oh-my-zsh' "$TEST_CASE_DIR/output"; then
  fail "failed oh-my-zsh clone produced a success message"
fi
grep -Fq 'Run `doctor` to verify' "$TEST_CASE_DIR/output" || fail "installer did not continue after oh-my-zsh clone failure"

INSTALL_TEST_PATH="$TEST_CASE_DIR/git-bin:/usr/bin:/bin"
run_installer --install-deps > "$TEST_CASE_DIR/output" 2>&1 || fail "missing Homebrew stopped the installer"
grep -Fq 'Homebrew not found' "$TEST_CASE_DIR/output" || fail "missing Homebrew was not reported"
unset INSTALL_TEST_PATH BREW_LOG

run_installer --bogus > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 2 ] || fail "unknown option did not exit with status 2 (got $status)"
grep -Fq 'Unknown option: --bogus' "$TEST_CASE_DIR/output" || fail "unknown option was not reported"

# A failed optional plugin clone is reported as failed, not successful, and the installer continues.
setup_fixture clone-failure
mkdir -p "$TEST_HOME/.oh-my-zsh" "$TEST_CASE_DIR/failing-bin" || fail "could not prepare clone failure case"
cat > "$TEST_CASE_DIR/failing-bin/git" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$TEST_CASE_DIR/failing-bin/git" || fail "could not make Git shim executable"
INSTALL_TEST_PATH="$TEST_CASE_DIR/failing-bin:$PATH"
export INSTALL_TEST_PATH
run_installer > "$TEST_CASE_DIR/output" 2>&1
status=$?
unset INSTALL_TEST_PATH
[ "$status" -eq 0 ] || fail "optional clone failure stopped the installer (status $status)"
grep -Fq 'Could not clone zsh-autosuggestions' "$TEST_CASE_DIR/output" || fail "failed plugin clone was not reported"
grep -Fq 'Could not clone zsh-syntax-highlighting' "$TEST_CASE_DIR/output" || fail "second failed plugin clone was not reported"
if grep -Fq 'Cloned zsh-' "$TEST_CASE_DIR/output"; then
  fail "failed plugin clone produced a success message"
fi
grep -Fq 'Run `doctor` to verify' "$TEST_CASE_DIR/output" || fail "installer did not continue to its final guidance after clone failures"

# The repository can live anywhere: shell config, links, and doctor follow its actual location.
relocate_fixture() {
  local destination="$1"
  mkdir -p "$(dirname "$destination")" || fail "could not create $destination parent"
  mv "$TEST_DOTFILES" "$destination" || fail "could not relocate fixture"
  TEST_DOTFILES="$destination"
}

setup_fixture relocated-in-home
relocate_fixture "$TEST_HOME/code/my-dots"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed from a custom directory under HOME"
run_installer > "$TEST_CASE_DIR/second-output" 2>&1 || fail "installer failed on rerun from a custom directory"
assert_link_target "$TEST_HOME/.gitconfig" "$TEST_DOTFILES/git/.gitconfig"
[ "$(grep -Fxc 'source ~/code/my-dots/alias/.alias' "$TEST_HOME/.zshrc")" -eq 1 ] || fail "custom directory alias source was not added exactly once"
[ "$(grep -Fxc 'source ~/code/my-dots/zsh/.zshrc.shared' "$TEST_HOME/.zshrc")" -eq 1 ] || fail "custom directory shared source was not added exactly once"
[ "$(grep -Fxc 'export PATH="$HOME/code/my-dots/scripts:$PATH"' "$TEST_HOME/.zshrc")" -eq 1 ] || fail "custom directory scripts PATH was not added exactly once"
if grep -Fq '~/dotfiles' "$TEST_HOME/.zshrc"; then
  fail "custom directory install wrote the default ~/dotfiles path"
fi
HOME="$TEST_HOME" PATH="$TEST_DOTFILES/scripts:$PATH" "$REAL_BASH" "$TEST_DOTFILES/scripts/doctor" > "$TEST_CASE_DIR/doctor-output" 2>&1
grep -Fq 'PASS: Aliases are sourced' "$TEST_CASE_DIR/doctor-output" || fail "doctor did not recognize the custom directory alias source"
grep -Fq 'PASS: Scripts PATH is exported' "$TEST_CASE_DIR/doctor-output" || fail "doctor did not recognize the custom directory scripts PATH"

# A stale line from the old default location does not count for a repository that moved.
setup_fixture moved-from-default
printf 'source ~/dotfiles/alias/.alias\n' > "$TEST_HOME/.zshrc"
relocate_fixture "$TEST_HOME/elsewhere"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed after the repository moved"
[ "$(grep -Fxc 'source ~/elsewhere/alias/.alias' "$TEST_HOME/.zshrc")" -eq 1 ] || fail "moved repository alias source was not added"

# A location outside HOME is written as an absolute path.
setup_fixture outside-home
relocate_fixture "$TEST_CASE_DIR/outside/dots"
run_installer > "$TEST_CASE_DIR/output" 2>&1 || fail "installer failed from a directory outside HOME"
run_installer > "$TEST_CASE_DIR/second-output" 2>&1 || fail "installer failed on rerun from a directory outside HOME"
[ "$(grep -Fxc "source $TEST_DOTFILES/alias/.alias" "$TEST_HOME/.zshrc")" -eq 1 ] || fail "absolute alias source was not added exactly once"
[ "$(grep -Fxc "export PATH=\"$TEST_DOTFILES/scripts:\$PATH\"" "$TEST_HOME/.zshrc")" -eq 1 ] || fail "absolute scripts PATH was not added exactly once"

# A path that cannot be written safely to ~/.zshrc is rejected before anything changes.
setup_fixture unsafe-path
relocate_fixture "$TEST_HOME/my dots"
run_installer > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -ne 0 ] || fail "installer accepted a path with a space"
grep -Fq 'cannot be written safely' "$TEST_CASE_DIR/output" || fail "unsafe path was not explained"
[ ! -e "$TEST_HOME/.zshrc" ] || fail "installer changed ~/.zshrc despite an unsafe path"

echo "install regression checks passed"
