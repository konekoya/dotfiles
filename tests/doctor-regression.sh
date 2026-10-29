#!/bin/bash
# Description: Regression coverage for doctor health-check semantics
# shellcheck disable=SC2088 # "~/..." in messages is literal text, not a path to expand

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_ENV="$(command -v env)"
REAL_FIND="$(command -v find)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/doctor-regression.XXXXXX")" || exit 1
# Scripts report their location through pwd, so use the same normalized path in expectations.
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)" || exit 1
TEST_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_BIN" || exit 1

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
  local tool
  TEST_CASE_DIR="$TEST_ROOT/$name"
  TEST_HOME="$TEST_CASE_DIR/home"
  TEST_DOTFILES="$TEST_HOME/dotfiles"
  TEST_SKILL="$TEST_DOTFILES/skills/sample-skill"
  mkdir -p "$TEST_DOTFILES/git" "$TEST_DOTFILES/alias" "$TEST_DOTFILES/scripts" "$TEST_DOTFILES/lib" "$TEST_SKILL" || fail "could not create fixture for $name"
  # doctor locates the dotfiles directory from its own path, so run a copy inside the fixture.
  DOCTOR="$TEST_DOTFILES/scripts/doctor"
  cp "$REPO_ROOT/scripts/doctor" "$DOCTOR" || fail "could not copy doctor for $name"
  cp "$REPO_ROOT/lib/agent-policy.sh" "$TEST_DOTFILES/lib/" || fail "could not copy agent policy helper"
  mkdir -p "$TEST_DOTFILES/agents" || fail "could not create policy directory"
  cp "$REPO_ROOT/agents/security.md" "$TEST_DOTFILES/agents/" || fail "could not copy policy"
  cp "$REPO_ROOT/lib/shell-config.sh" "$TEST_DOTFILES/lib/" || fail "could not copy shell helpers for $name"
  cp "$REPO_ROOT/lib/local-env.sh" "$REPO_ROOT/lib/work-notes.sh" "$REPO_ROOT/lib/morning.sh" "$TEST_DOTFILES/lib/" || fail "could not copy work notes helpers for $name"
  cp "$REPO_ROOT/git/.gitconfig" "$TEST_DOTFILES/git/.gitconfig" || fail "could not copy git config for $name"
  cp "$REPO_ROOT/git/.gitignore_global" "$TEST_DOTFILES/git/.gitignore_global" || fail "could not copy gitignore for $name"
  printf '# sample skill\n' > "$TEST_SKILL/SKILL.md"
  : > "$TEST_DOTFILES/alias/.env"
  mkdir -p "$TEST_HOME/.claude/skills" "$TEST_HOME/.copilot/skills" "$TEST_HOME/.agents/skills" "$TEST_HOME/.kiro/skills" || fail "could not create tool directories for $name"
  ln -s "$TEST_DOTFILES/git/.gitconfig" "$TEST_HOME/.gitconfig" || fail "could not link git config for $name"
  ln -s "$TEST_DOTFILES/git/.gitignore_global" "$TEST_HOME/.gitignore_global" || fail "could not link gitignore for $name"
  for tool_dir in "$TEST_HOME/.claude/skills" "$TEST_HOME/.copilot/skills" "$TEST_HOME/.agents/skills" "$TEST_HOME/.kiro/skills"; do
    ln -s "$TEST_SKILL" "$tool_dir/sample-skill" || fail "could not link skill for $name"
  done
  cat > "$TEST_HOME/.zshrc" <<'EOF'
source "$HOME/dotfiles/alias/.alias"
export PATH="$HOME/dotfiles/scripts:$PATH"
EOF

  for tool in grep readlink tr awk stat dirname find git zsh sed; do
    if [ ! -e "$TEST_BIN/$tool" ]; then
      tool_path="$(command -v "$tool")" || fail "required test utility '$tool' is unavailable"
      ln -s "$tool_path" "$TEST_BIN/$tool" || fail "could not add '$tool' to test PATH"
    fi
  done
}

run_doctor() {
  "$REAL_ENV" -i HOME="$TEST_HOME" PATH="$TEST_BIN" "$@" "$DOCTOR"
}

assert_secret_not_printed() {
  local secret="$1"
  grep -Fq -- "$secret" "$TEST_CASE_DIR/output" && fail "doctor output exposed a configured value"
}

setup_fixture warnings-only
run_doctor > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "warnings alone returned status $status"
grep -Fq 'Codex CLI: optional global security policy is missing' "$TEST_CASE_DIR/output" || fail "missing optional policy not reported"
grep -Fq '⚠️ WARN: docker not found' "$TEST_CASE_DIR/output" || fail "missing Docker was not reported as a warning"
grep -Fq '⚠️ WARN: GIT_WORK_NAME and GIT_WORK_EMAIL are optional' "$TEST_CASE_DIR/output" || fail "missing work Git identity was not reported as a warning"
grep -Fq '⚠️ WARN: starship not found — shared prompt unavailable' "$TEST_CASE_DIR/output" || fail "missing starship was not reported as a warning"
grep -Fq '⚠️ WARN: delta not found — configured Git pager is unavailable (brew install git-delta)' "$TEST_CASE_DIR/output" || fail "missing delta warning did not explain the configured Git pager"
grep -Fq '⚠️ WARN: python3 not found — server alias and some regression checks are unavailable (brew install python)' "$TEST_CASE_DIR/output" || fail "missing python3 was not reported as a warning"
grep -Fq '⚠️ WARN: magick not found — image-shrink is unavailable (brew install imagemagick)' "$TEST_CASE_DIR/output" || fail "missing ImageMagick was not reported as a warning"
grep -Fq '❌ 0 failures' "$TEST_CASE_DIR/output" || fail "warnings-only summary reported a failure"
# gawk and pyenv are workstation baseline packages, not dotfiles dependencies.
if grep -Eq 'gawk|pyenv' "$TEST_CASE_DIR/output"; then
  fail "doctor checked a workstation baseline package"
fi

# doctor only looks python3 up with command -v, so a stub is enough; never run the real server alias.
mkdir -p "$TEST_CASE_DIR/python-bin" || fail "could not create python3 stub directory"
printf '#!/bin/bash\nexit 0\n' > "$TEST_CASE_DIR/python-bin/python3"
chmod +x "$TEST_CASE_DIR/python-bin/python3" || fail "could not make python3 stub executable"
run_doctor PATH="$TEST_CASE_DIR/python-bin:$TEST_BIN" > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "available python3 returned status $status"
grep -Fq '✅ PASS: python3 installed' "$TEST_CASE_DIR/output" || fail "available python3 was not reported as PASS"
if grep -Fq 'python3 not found' "$TEST_CASE_DIR/output"; then
  fail "available python3 was still reported missing"
fi

mkdir -p "$TEST_CASE_DIR/image-bin" || fail "could not create ImageMagick stub directory"
cat > "$TEST_CASE_DIR/image-bin/magick" <<'EOF'
#!/bin/bash
printf 'HEIC HEIC rw+ Apple High Efficiency Image Format\n'
EOF
chmod +x "$TEST_CASE_DIR/image-bin/magick" || fail "could not make ImageMagick stub executable"
run_doctor PATH="$TEST_CASE_DIR/image-bin:$TEST_BIN" > "$TEST_CASE_DIR/output" 2>&1
[ "$?" -eq 0 ] || fail "available ImageMagick failed doctor"
grep -Fq '✅ PASS: magick installed' "$TEST_CASE_DIR/output" || fail "available ImageMagick was not recognized"
grep -Fq '✅ PASS: ImageMagick HEIC reading and writing are available' "$TEST_CASE_DIR/output" || fail "HEIC support was not recognized"
cat > "$TEST_CASE_DIR/image-bin/magick" <<'EOF'
#!/bin/bash
printf 'JPEG* JPEG rw- JPEG format\n'
EOF
run_doctor PATH="$TEST_CASE_DIR/image-bin:$TEST_BIN" > "$TEST_CASE_DIR/output" 2>&1
[ "$?" -eq 0 ] || fail "missing HEIC codec failed doctor instead of warning"
grep -Fq '⚠️ WARN: ImageMagick HEIC support is unavailable' "$TEST_CASE_DIR/output" || fail "missing HEIC codec was not reported"

run_doctor PATH="$TEST_DOTFILES/scripts:$TEST_BIN" > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "exact scripts PATH entry returned status $status"
grep -Fq '✅ PASS: dotfiles/scripts is in PATH' "$TEST_CASE_DIR/output" || fail "exact scripts PATH entry was not recognized"

run_doctor PATH="$TEST_DOTFILES/scripts-old:$TEST_BIN" > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "scripts-old PATH entry returned status $status"
grep -Fq '⚠️ WARN: dotfiles/scripts is not in current PATH' "$TEST_CASE_DIR/output" || fail "scripts-old was incorrectly accepted as the scripts PATH entry"
if grep -Fq '✅ PASS: dotfiles/scripts is in PATH' "$TEST_CASE_DIR/output"; then
  fail "scripts-old was accepted as the scripts PATH entry"
fi

setup_fixture shared-zsh-config
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq '⚠️ WARN: Missing: source ~/dotfiles/zsh/.zshrc.shared' "$TEST_CASE_DIR/output" || fail "missing shared zsh source was not reported"
grep -Fq '⚠️ WARN: ~/.config/starship.toml is missing' "$TEST_CASE_DIR/output" || fail "missing starship link was not reported"
mkdir -p "$TEST_DOTFILES/zsh" "$TEST_HOME/.config" || fail "could not create zsh fixture directories"
: > "$TEST_DOTFILES/zsh/starship.toml"
: > "$TEST_DOTFILES/zsh/.zshrc.local"
ln -s "$TEST_DOTFILES/zsh/starship.toml" "$TEST_HOME/.config/starship.toml" || fail "could not link starship config"
printf 'source ~/dotfiles/zsh/.zshrc.shared\n' >> "$TEST_HOME/.zshrc"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "configured shared zsh setup returned status $status"
grep -Fq '✅ PASS: ~/.zshrc is configured to source the shared zsh config' "$TEST_CASE_DIR/output" || fail "shared zsh source was not recognized"
grep -Fq '✅ PASS: ~/.config/starship.toml →' "$TEST_CASE_DIR/output" || fail "starship link was not recognized"
grep -Fq '✅ PASS: zsh/.zshrc.local exists' "$TEST_CASE_DIR/output" || fail "zsh local file was not recognized"

setup_fixture zsh-plugin-integrity
ALT_ZSH_DIR="$TEST_HOME/oh-my-zsh-alt"
ALT_ZSH_CUSTOM="$TEST_HOME/zsh-custom-alt"
mkdir -p "$TEST_DOTFILES/zsh" "$ALT_ZSH_DIR" "$ALT_ZSH_CUSTOM/plugins/zsh-autosuggestions" "$ALT_ZSH_CUSTOM/plugins/zsh-syntax-highlighting" || fail "could not create zsh plugin fixture"
printf '# synthetic oh-my-zsh entrypoint\n' > "$ALT_ZSH_DIR/oh-my-zsh.sh"
cp "$REPO_ROOT/zsh/.zshrc.shared" "$TEST_DOTFILES/zsh/.zshrc.shared" || fail "could not copy shared zsh config"
printf '# synthetic plugin entrypoint\n' > "$ALT_ZSH_CUSTOM/plugins/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh"
printf '# synthetic plugin entrypoint\n' > "$ALT_ZSH_CUSTOM/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh"
run_doctor ZSH="$ALT_ZSH_DIR" ZSH_CUSTOM="$ALT_ZSH_CUSTOM" > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "complete zsh plugins returned status $status"
grep -Fq '✅ PASS: oh-my-zsh entrypoint is present and readable' "$TEST_CASE_DIR/output" || fail "alternate Oh My Zsh path was not recognized"
grep -Fq '✅ PASS: zsh-autosuggestions entrypoint is present, readable, and non-empty' "$TEST_CASE_DIR/output" || fail "autosuggestions entrypoint was not validated"
grep -Fq '✅ PASS: zsh-syntax-highlighting entrypoint is present, readable, and non-empty' "$TEST_CASE_DIR/output" || fail "syntax-highlighting entrypoint was not validated"
grep -Fq '⚠️ WARN: zsh-autosuggestions is configured in the shared zsh config, but ~/.zshrc does not source it' "$TEST_CASE_DIR/output" || fail "missing shared zsh source was not connected to plugin status"
printf 'source ~/dotfiles/zsh/.zshrc.shared\n' >> "$TEST_HOME/.zshrc"
run_doctor ZSH="$ALT_ZSH_DIR" ZSH_CUSTOM="$ALT_ZSH_CUSTOM" > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "configured zsh plugins returned status $status"
grep -Fq '✅ PASS: zsh-autosuggestions is configured in the shared zsh config (runtime loading is not verified)' "$TEST_CASE_DIR/output" || fail "autosuggestions configuration status was not recognized"
grep -Fq '✅ PASS: zsh-syntax-highlighting is configured in the shared zsh config (runtime loading is not verified)' "$TEST_CASE_DIR/output" || fail "syntax-highlighting configuration status was not recognized"

rm -r "$ALT_ZSH_CUSTOM/plugins/zsh-autosuggestions" || fail "could not remove synthetic plugin directory"
run_doctor ZSH="$ALT_ZSH_DIR" ZSH_CUSTOM="$ALT_ZSH_CUSTOM" > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "missing zsh plugin returned status $status"
grep -Fq '⚠️ WARN: zsh-autosuggestions is not installed under the effective ZSH_CUSTOM path — install it there to enable the shared loader' "$TEST_CASE_DIR/output" || fail "missing plugin directory was not reported"

mkdir -p "$ALT_ZSH_CUSTOM/plugins/zsh-autosuggestions" || fail "could not recreate synthetic plugin directory"
run_doctor ZSH="$ALT_ZSH_DIR" ZSH_CUSTOM="$ALT_ZSH_CUSTOM" > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "incomplete zsh plugin returned status $status"
grep -Fq '⚠️ WARN: zsh-autosuggestions installation is incomplete' "$TEST_CASE_DIR/output" || fail "incomplete plugin directory was not reported"

printf '# zsh-autosuggestions.plugin.zsh\n# source "$_dotfiles_plugin_file"\n' > "$TEST_DOTFILES/zsh/.zshrc.shared"
run_doctor ZSH="$ALT_ZSH_DIR" ZSH_CUSTOM="$ALT_ZSH_CUSTOM" > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "commented zsh plugin loader returned status $status"
grep -Fq '⚠️ WARN: zsh-autosuggestions is not configured across the supported shared zsh loading paths' "$TEST_CASE_DIR/output" || fail "commented plugin references were treated as active loading"

cat > "$TEST_DOTFILES/zsh/.zshrc.shared" <<'EOF'
plugins=(git zsh-autosuggestions)
if [[ "$_dotfiles_omz_preloaded" == true ]]; then
  _dotfiles_plugin_file="custom/plugins/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh"
  [ -f "$_dotfiles_plugin_file" ] && source "$_dotfiles_plugin_file"
fi
_dotfiles_plugin_file="custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh"
[ -f "$_dotfiles_plugin_file" ] && source "$_dotfiles_plugin_file"
eval "$_dotfiles_fzf_init"
EOF
run_doctor ZSH="$ALT_ZSH_DIR" ZSH_CUSTOM="$ALT_ZSH_CUSTOM" > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "misordered zsh plugin loader returned status $status"
grep -Fq '⚠️ WARN: zsh-syntax-highlighting is not configured across the supported shared zsh loading paths' "$TEST_CASE_DIR/output" || fail "early syntax-highlighting load was not reported"

# Syntax highlighting has a direct shared-config loader; autosuggestions depends on Oh My Zsh.
setup_fixture zsh-without-oh-my-zsh
mkdir -p "$TEST_DOTFILES/zsh" "$TEST_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" || fail "could not create no-Oh-My-Zsh fixture"
cp "$REPO_ROOT/zsh/.zshrc.shared" "$TEST_DOTFILES/zsh/.zshrc.shared" || fail "could not copy shared zsh config"
: > "$TEST_DOTFILES/zsh/.zshrc.local"
printf '# synthetic plugin entrypoint\n' > "$TEST_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh"
printf 'source ~/dotfiles/zsh/.zshrc.shared\n' >> "$TEST_HOME/.zshrc"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "missing Oh My Zsh returned status $status"
grep -Fq '⚠️ WARN: oh-my-zsh entrypoint is not present at the effective ZSH path' "$TEST_CASE_DIR/output" || fail "missing Oh My Zsh was not reported"
grep -Fq '✅ PASS: zsh-syntax-highlighting entrypoint is present, readable, and non-empty' "$TEST_CASE_DIR/output" || fail "direct syntax-highlighting entrypoint was skipped without Oh My Zsh"
grep -Fq '✅ PASS: zsh-syntax-highlighting is configured in the shared zsh config (runtime loading is not verified)' "$TEST_CASE_DIR/output" || fail "direct syntax-highlighting loader was skipped without Oh My Zsh"
grep -Fq '⚠️ WARN: zsh-autosuggestions is configured in the shared zsh config, but Oh My Zsh is absent' "$TEST_CASE_DIR/output" || fail "autosuggestions status did not account for missing Oh My Zsh"

# Runtime coverage sources only the repository config copy and synthetic plugins in isolated homes.
cp "$REPO_ROOT/zsh/.zshrc.shared" "$TEST_DOTFILES/zsh/.zshrc.shared" || fail "could not restore shared zsh config"
mkdir -p "$TEST_DOTFILES/zsh" "$TEST_HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" "$TEST_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" "$TEST_CASE_DIR/runtime-bin" || fail "could not create runtime plugin fixture"
: > "$TEST_DOTFILES/zsh/.zshrc.local"
cat > "$TEST_HOME/.oh-my-zsh/oh-my-zsh.sh" <<'EOF'
function omz { :; }
for _plugin in "${plugins[@]}"; do
  _plugin_file="$ZSH_CUSTOM/plugins/$_plugin/$_plugin.plugin.zsh"
  [[ -r "$_plugin_file" ]] && source "$_plugin_file"
done
EOF
cat > "$TEST_HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh" <<'EOF'
(( DOTFILES_AUTOSUGGEST_LOADS += 1 ))
DOTFILES_PLUGIN_ORDER="${DOTFILES_PLUGIN_ORDER}autosuggestions "
function _zsh_autosuggest_start { :; }
EOF
cat > "$TEST_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh" <<'EOF'
(( DOTFILES_HIGHLIGHT_LOADS += 1 ))
DOTFILES_PLUGIN_ORDER="${DOTFILES_PLUGIN_ORDER}syntax-highlighting "
DOTFILES_HIGHLIGHT_SAW_STARSHIP="$DOTFILES_STARSHIP_INIT"
function _zsh_highlight { :; }
EOF
cat > "$TEST_CASE_DIR/runtime-bin/starship" <<'EOF'
#!/bin/sh
printf 'DOTFILES_STARSHIP_INIT=initialized\n'
EOF
chmod +x "$TEST_CASE_DIR/runtime-bin/starship" || fail "could not make the starship test stub executable"
cat > "$TEST_CASE_DIR/normal-loading.zsh" <<EOF
typeset -gi DOTFILES_AUTOSUGGEST_LOADS=0
typeset -gi DOTFILES_HIGHLIGHT_LOADS=0
DOTFILES_PLUGIN_ORDER=''
source "$TEST_DOTFILES/zsh/.zshrc.shared"
[[ "\$DOTFILES_AUTOSUGGEST_LOADS" == 1 && "\$DOTFILES_HIGHLIGHT_LOADS" == 1 ]] || exit 1
[[ "\$DOTFILES_PLUGIN_ORDER" == 'autosuggestions syntax-highlighting ' ]] || exit 1
[[ "\$DOTFILES_HIGHLIGHT_SAW_STARSHIP" == initialized ]] || exit 1
EOF
if ! "$REAL_ENV" -i HOME="$TEST_HOME" ZSH="$TEST_HOME/.oh-my-zsh" ZSH_CUSTOM="$TEST_HOME/.oh-my-zsh/custom" PATH="$TEST_CASE_DIR/runtime-bin:$TEST_BIN" "$TEST_BIN/zsh" -f "$TEST_CASE_DIR/normal-loading.zsh" > "$TEST_CASE_DIR/runtime-output" 2>&1; then
  fail "normal Oh My Zsh plugin loading smoke check failed"
fi

cat > "$TEST_CASE_DIR/preloaded-loading.zsh" <<EOF
typeset -gi DOTFILES_AUTOSUGGEST_LOADS=1
typeset -gi DOTFILES_HIGHLIGHT_LOADS=1
DOTFILES_PLUGIN_ORDER='preloaded '
plugins=(git zsh-autosuggestions)
function omz { :; }
function _zsh_autosuggest_start { :; }
function _zsh_highlight { :; }
source "$TEST_DOTFILES/zsh/.zshrc.shared"
[[ "\$DOTFILES_AUTOSUGGEST_LOADS" == 1 && "\$DOTFILES_HIGHLIGHT_LOADS" == 1 ]] || exit 1
EOF
if ! "$REAL_ENV" -i HOME="$TEST_HOME" ZSH="$TEST_HOME/.oh-my-zsh" ZSH_CUSTOM="$TEST_HOME/.oh-my-zsh/custom" PATH="$TEST_CASE_DIR/runtime-bin:$TEST_BIN" "$TEST_BIN/zsh" -f "$TEST_CASE_DIR/preloaded-loading.zsh" > "$TEST_CASE_DIR/runtime-output" 2>&1; then
  fail "preloaded Oh My Zsh duplicate-loading smoke check failed"
fi

# A synthetic Hack Nerd Font filename exercises the limited font-file check.
setup_fixture nerd-font
mkdir -p "$TEST_DOTFILES/zsh" "$TEST_CASE_DIR/starship-bin" || fail "could not create font test fixture"
: > "$TEST_DOTFILES/zsh/.zshrc.local"
cp "$REPO_ROOT/zsh/.zshrc.shared" "$TEST_DOTFILES/zsh/.zshrc.shared" || fail "could not copy shared zsh config for font test"
printf 'source ~/dotfiles/zsh/.zshrc.shared\n' >> "$TEST_HOME/.zshrc"
printf '#!/bin/bash\nexit 0\n' > "$TEST_CASE_DIR/starship-bin/starship"
chmod +x "$TEST_CASE_DIR/starship-bin/starship" || fail "could not make starship stub executable"
run_doctor PATH="$TEST_CASE_DIR/starship-bin:$TEST_BIN" > "$TEST_CASE_DIR/output" 2>&1
if ! "$REAL_FIND" "$TEST_HOME/Library/Fonts" -type f \( -iname 'HackNerdFont*.ttf' -o -iname 'HackNerdFont*.otf' \) -print -quit 2>/dev/null | grep -q . &&
  ! "$REAL_FIND" /Library/Fonts -type f \( -iname 'HackNerdFont*.ttf' -o -iname 'HackNerdFont*.otf' \) -print -quit 2>/dev/null | grep -q .; then
  grep -Fq '⚠️ WARN: Hack Nerd Font installation is not verified' "$TEST_CASE_DIR/output" || fail "unverified Hack Nerd Font was not reported"
fi
mkdir -p "$TEST_HOME/Library/Fonts" || fail "could not create font directory"
printf 'synthetic font fixture\n' > "$TEST_HOME/Library/Fonts/HackNerdFont-Regular.ttf"
run_doctor PATH="$TEST_CASE_DIR/starship-bin:$TEST_BIN" > "$TEST_CASE_DIR/output" 2>&1
grep -Fq '✅ PASS: Hack Nerd Font file is present; macOS font registration, terminal font selection, and glyph rendering are not verified' "$TEST_CASE_DIR/output" || fail "Hack Nerd Font file presence was not recognized"

setup_fixture core-failure
rm "$TEST_HOME/.gitconfig" || fail "could not remove core symlink for failure case"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -ne 0 ] || fail "core symlink failure returned status 0"
grep -Fq '❌ FAIL: ~/.gitconfig is missing — run install.sh' "$TEST_CASE_DIR/output" || fail "missing Git config did not recommend installation"

# skill-creator is expected only outside Claude Code, where the plugin ships it.
setup_fixture claude-plugin-skill
mkdir -p "$TEST_DOTFILES/skills/skill-creator" || fail "could not prepare plugin skill"
printf '# skill creator\n' > "$TEST_DOTFILES/skills/skill-creator/SKILL.md"
for tool_dir in "$TEST_HOME/.copilot/skills" "$TEST_HOME/.agents/skills" "$TEST_HOME/.kiro/skills"; do
  ln -s "$TEST_DOTFILES/skills/skill-creator" "$tool_dir/skill-creator" || fail "could not link plugin skill"
done
run_doctor > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "skipped Claude skill returned status $status"
grep -Fq '✅ PASS: Claude Code: all 1 shared skill links are correct' "$TEST_CASE_DIR/output" || fail "skipped skill was expected for Claude Code"
grep -Fq '✅ PASS: Kiro CLI: all 2 shared skill links are correct' "$TEST_CASE_DIR/output" || fail "plugin skill was not expected for Kiro CLI"

ln -s "$TEST_DOTFILES/skills/skill-creator" "$TEST_HOME/.claude/skills/skill-creator" || fail "could not add duplicate Claude link"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "duplicate Claude skill link returned status $status"
grep -Fq '⚠️ WARN: Claude Code: skill-creator duplicates the bundled plugin — run install.sh to remove the link' "$TEST_CASE_DIR/output" || fail "duplicate Claude skill link was not reported"

setup_fixture relative-git-links
for target_name in .gitconfig .gitignore_global; do
  rm "$TEST_HOME/$target_name" || fail "could not remove absolute $target_name link"
  ln -s "dotfiles/git/$target_name" "$TEST_HOME/$target_name" || fail "could not create relative $target_name link"
done
run_doctor > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "working relative Git config links returned status $status"
for target_name in .gitconfig .gitignore_global; do
  grep -Fq "✅ PASS: ~/$target_name → $TEST_DOTFILES/git/$target_name" "$TEST_CASE_DIR/output" || fail "working relative $target_name link was not recognized"
done

for target_name in .gitconfig .gitignore_global; do
  for state in regular-file unrelated-symlink broken-symlink; do
    setup_fixture "$target_name-$state"
    target_path="$TEST_HOME/$target_name"
    rm "$target_path" || fail "could not prepare $target_name conflict"
    case "$state" in
      regular-file)
        printf 'user configuration\n' > "$target_path"
        ;;
      unrelated-symlink)
        printf 'unrelated configuration\n' > "$TEST_CASE_DIR/unrelated-target"
        ln -s "$TEST_CASE_DIR/unrelated-target" "$target_path" || fail "could not create unrelated $target_name link"
        ;;
      broken-symlink)
        ln -s "$TEST_CASE_DIR/missing-target" "$target_path" || fail "could not create broken $target_name link"
        ;;
    esac
    run_doctor > "$TEST_CASE_DIR/output" 2>&1
    status=$?
    [ "$status" -ne 0 ] || fail "$target_name $state conflict returned status 0"
    grep -Fq "❌ FAIL: ~/$target_name is not a working symlink" "$TEST_CASE_DIR/output" || fail "$target_name conflict was not reported"
    grep -Fq 'review and resolve this existing path manually; install.sh preserves it' "$TEST_CASE_DIR/output" || fail "$target_name conflict did not explain the need for manual review"
    case "$state" in
      regular-file)
        [ ! -L "$target_path" ] && [ "$(cat "$target_path")" = 'user configuration' ] || fail "doctor changed existing $target_name file"
        ;;
      unrelated-symlink)
        [ "$(readlink "$target_path")" = "$TEST_CASE_DIR/unrelated-target" ] || fail "doctor changed unrelated $target_name link"
        [ "$(cat "$TEST_CASE_DIR/unrelated-target")" = 'unrelated configuration' ] || fail "doctor changed unrelated $target_name target"
        ;;
      broken-symlink)
        [ "$(readlink "$target_path")" = "$TEST_CASE_DIR/missing-target" ] && [ ! -e "$target_path" ] || fail "doctor changed broken $target_name link"
        ;;
    esac
  done
done

setup_fixture env-file-values
cat > "$TEST_DOTFILES/alias/.env" <<'EOF'
GIT_WORK_NAME='file-name-secret'
GIT_WORK_EMAIL='file-email-secret'
CLICKUP_API_TOKEN='file-clickup-secret'
EOF
run_doctor > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "values loaded from .env returned status $status"
grep -Fq 'PASS: Work Git identity is configured for config-git' "$TEST_CASE_DIR/output" || fail "configured .env work identity was not reported as PASS"
grep -Fq 'PASS: ClickUp API token is configured' "$TEST_CASE_DIR/output" || fail "configured .env ClickUp token was not reported as PASS"
assert_secret_not_printed file-name-secret
assert_secret_not_printed file-email-secret
assert_secret_not_printed file-clickup-secret
chmod 644 "$TEST_DOTFILES/alias/.env" || fail "could not set broad permissions"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq 'alias/.env grants group or other access' "$TEST_CASE_DIR/output" || fail "broad environment permissions were not reported"
chmod 600 "$TEST_DOTFILES/alias/.env" || fail "could not set private permissions"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq 'alias/.env permissions restrict access to its owner' "$TEST_CASE_DIR/output" || fail "private environment permissions were not recognized"
assert_secret_not_printed file-clickup-secret

setup_fixture commented-shell-settings
cat > "$TEST_HOME/.zshrc" <<'EOF'
# source ~/dotfiles/alias/.alias
# export PATH="$HOME/dotfiles/scripts:$PATH"
echo 'source ~/dotfiles/alias/.alias'
echo 'dotfiles/scripts'
EOF
if run_doctor > "$TEST_CASE_DIR/output" 2>&1; then fail "commented shell settings passed"; fi
grep -Fq 'FAIL: Missing: source' "$TEST_CASE_DIR/output" || fail "commented alias source was accepted"
grep -Fq 'FAIL: Missing: export PATH=' "$TEST_CASE_DIR/output" || fail "commented PATH was accepted"

cat > "$TEST_HOME/.zshrc" <<'EOF'
  . "${HOME}/dotfiles/alias/.alias" # load aliases
  export PATH="$PATH:${HOME}/dotfiles/scripts" # add scripts
EOF
run_doctor > "$TEST_CASE_DIR/output" 2>&1 || fail "active shell setting variations were rejected"

setup_fixture environment-precedence
SOURCE_MARKER="$TEST_CASE_DIR/dotenv-was-read"
cat > "$TEST_DOTFILES/alias/.env" <<EOF
GIT_WORK_NAME='dotenv-name-secret'
GIT_WORK_EMAIL='dotenv-email-secret'
CLICKUP_API_TOKEN='dotenv-clickup-secret'
: > '$SOURCE_MARKER'
EOF
run_doctor \
  GIT_WORK_NAME=environment-name-secret \
  GIT_WORK_EMAIL=environment-email-secret \
  CLICKUP_API_TOKEN=environment-clickup-secret \
  WORK_NOTES_REPO=environment-notes-secret \
  WORK_NOTES_DIR="$TEST_HOME/work-notes" \
  MORNING_REPOS="$TEST_HOME/code/sample-project" \
  > "$TEST_CASE_DIR/output" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "environment configuration returned status $status"
[ ! -e "$SOURCE_MARKER" ] || fail "doctor sourced .env despite all values being present in the environment"
grep -Fq 'PASS: Work Git identity is configured for config-git' "$TEST_CASE_DIR/output" || fail "environment work identity was not reported as PASS"
grep -Fq 'PASS: ClickUp API token is configured' "$TEST_CASE_DIR/output" || fail "environment ClickUp token was not reported as PASS"
assert_secret_not_printed environment-name-secret
assert_secret_not_printed environment-email-secret
assert_secret_not_printed environment-clickup-secret
assert_secret_not_printed environment-notes-secret
assert_secret_not_printed dotenv-name-secret
assert_secret_not_printed dotenv-email-secret
assert_secret_not_printed dotenv-clickup-secret

# Git identity comes from ~/.gitconfig.local through the shared config's include.
setup_fixture git-identity
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq '⚠️ WARN: ~/.gitconfig.local is missing' "$TEST_CASE_DIR/output" || fail "missing ~/.gitconfig.local was not reported"
grep -Fq '⚠️ WARN: Git user.name or user.email is not set' "$TEST_CASE_DIR/output" || fail "missing Git identity was not reported"
printf '[user]\n\tname = Test User\n\temail = test@example.com\n' > "$TEST_HOME/.gitconfig.local"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq '✅ PASS: ~/.gitconfig.local exists' "$TEST_CASE_DIR/output" || fail "existing ~/.gitconfig.local was not recognized"
grep -Fq '✅ PASS: Git user.name and user.email are set' "$TEST_CASE_DIR/output" || fail "configured Git identity was not recognized"
assert_secret_not_printed test@example.com

# The work identity file only matters once includeIf rules are enabled.
grep -Fq '~/.gitconfig.work' "$TEST_CASE_DIR/output" && fail "work identity was checked without includeIf rules"
printf '[user]\n\tname = Test User\n\temail = test@example.com\n# [includeIf "hasconfig:remote.*.url:https://*dev.azure.com/**"]\n' > "$TEST_HOME/.gitconfig.local"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq '~/.gitconfig.work' "$TEST_CASE_DIR/output" && fail "commented includeIf rule was treated as enabled"
printf '[includeIf "hasconfig:remote.*.url:https://*dev.azure.com/**"]\n\tpath = ~/.gitconfig.work\n' >> "$TEST_HOME/.gitconfig.local"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq '⚠️ WARN: ~/.gitconfig.local has includeIf rules but ~/.gitconfig.work is missing' "$TEST_CASE_DIR/output" || fail "missing work identity file was not reported"
: > "$TEST_HOME/.gitconfig.work"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq '✅ PASS: ~/.gitconfig.work exists' "$TEST_CASE_DIR/output" || fail "existing work identity file was not recognized"

# Repository freshness: doctor fetches the upstream and warns when the checkout is behind it.
setup_repo_fixture() {
  local name="$1"
  setup_fixture "$name"
  TEST_REMOTE="$TEST_CASE_DIR/remote.git"
  TEST_SEED="$TEST_CASE_DIR/seed"
  GIT_IDENTITY=(-c user.name=Test -c user.email=test@example.com)
  git init -q -b main --bare "$TEST_REMOTE" || fail "could not create remote for $name"
  git -C "$TEST_DOTFILES" init -q -b main || fail "could not initialize repository for $name"
  git -C "$TEST_DOTFILES" add -A || fail "could not stage fixture for $name"
  git -C "$TEST_DOTFILES" "${GIT_IDENTITY[@]}" commit -q -m initial || fail "could not commit fixture for $name"
  git -C "$TEST_DOTFILES" remote add origin "$TEST_REMOTE" || fail "could not add remote for $name"
  git -C "$TEST_DOTFILES" push -q -u origin main || fail "could not push fixture for $name"
  git clone -q "$TEST_REMOTE" "$TEST_SEED" || fail "could not clone seed for $name"
}

push_seed_commit() {
  printf '%s\n' "$1" >> "$TEST_SEED/notes"
  git -C "$TEST_SEED" add -A || fail "could not stage $1"
  git -C "$TEST_SEED" "${GIT_IDENTITY[@]}" commit -q -m "$1" || fail "could not commit $1"
  git -C "$TEST_SEED" push -q origin main || fail "could not push $1"
}

setup_repo_fixture repo-current
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq '✅ PASS: dotfiles is up to date with origin/main' "$TEST_CASE_DIR/output" || fail "up-to-date repository was not reported"

setup_repo_fixture repo-behind
push_seed_commit "feat: one"
push_seed_commit "feat: two"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq '⚠️ WARN: dotfiles is 2 commit(s) behind origin/main — run git pull in ~/dotfiles, then re-run install.sh' "$TEST_CASE_DIR/output" || fail "doctor did not warn about being behind"
[ "$(git -C "$TEST_DOTFILES" rev-parse HEAD)" != "$(git -C "$TEST_SEED" rev-parse HEAD)" ] || fail "doctor pulled changes"
git -C "$TEST_DOTFILES" pull -q --ff-only || fail "could not catch up"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq '✅ PASS: dotfiles is up to date with origin/main' "$TEST_CASE_DIR/output" || fail "caught-up repository still warned"

setup_repo_fixture repo-offline
git -C "$TEST_DOTFILES" remote set-url origin "$TEST_CASE_DIR/missing.git"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq '⚠️ WARN: Could not reach the remote' "$TEST_CASE_DIR/output" || fail "unreachable remote was not reported"

# Piped output has no progress text; a terminal shows a spinner that is cleared before the result.
grep -Fq 'Checking' "$TEST_CASE_DIR/output" && fail "progress text leaked into piped output"
setup_repo_fixture repo-spinner
mkdir -p "$TEST_CASE_DIR/slow-bin" || fail "could not create slow Git directory"
REAL_GIT="$(command -v git)"
cat > "$TEST_CASE_DIR/slow-bin/git" <<STUB
#!/bin/bash
case "\$*" in *fetch*) sleep 1 ;; esac
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$TEST_CASE_DIR/slow-bin/git" || fail "could not make slow Git shim executable"
python3 - "$REAL_ENV" "$TEST_HOME" "$TEST_CASE_DIR/slow-bin:$TEST_BIN" "$DOCTOR" > "$TEST_CASE_DIR/tty-output" <<'PYTHON'
import os, pty, select, signal, sys, time
env_bin, home, path, doctor = sys.argv[1:]
# pty.spawn waits for EOF on the master, which macOS's system Python 3.9 never sees after the
# child exits. Stop once the child has exited and its output is drained, with a deadline.
pid, fd = pty.fork()
if pid == 0:
    os.execv(env_bin, [env_bin, "-i", "HOME=" + home, "PATH=" + path, doctor])
chunks = []
deadline = time.monotonic() + 30
while True:
    if time.monotonic() > deadline:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        sys.exit("terminal run did not finish within 30 seconds")
    if select.select([fd], [], [], 0.1)[0]:
        try:
            data = os.read(fd, 4096)
        except OSError:
            data = b""
        if not data:
            os.waitpid(pid, 0)
            break
        chunks.append(data)
    elif os.waitpid(pid, os.WNOHANG)[0]:
        break
sys.stdout.buffer.write(b"".join(chunks))
PYTHON
grep -Fq 'Checking origin/main for updates...' "$TEST_CASE_DIR/tty-output" || fail "terminal run showed no checking indicator"
grep -Fq 'PASS: dotfiles is up to date with origin/main' "$TEST_CASE_DIR/tty-output" || fail "terminal run lost the repository result"

# Without a Git checkout or upstream there is nothing to compare, so the section is skipped.
setup_fixture not-a-repo
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq 'Repository' "$TEST_CASE_DIR/output" && fail "repository check ran outside a Git checkout"

# Work notes are optional; a configured but missing checkout is reported without its URL.
setup_fixture work-notes-unconfigured
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq 'WARN: Work notes are optional and not configured' "$TEST_CASE_DIR/output" || fail "unconfigured work notes were not reported"

setup_fixture work-notes-missing
run_doctor WORK_NOTES_REPO="git@example.invalid:placeholder/notes.git" > "$TEST_CASE_DIR/output" 2>&1
grep -Fq 'WARN: WORK_NOTES_REPO is set but ~/work-notes is missing' "$TEST_CASE_DIR/output" || fail "missing work notes checkout was not reported"
assert_secret_not_printed "placeholder/notes.git"

# A synced checkout passes; unlinked targets, local changes, and unpushed commits warn.
setup_fixture work-notes-present
WORK_NOTES_ORIGIN="$TEST_CASE_DIR/work-notes-origin.git"
WORK_NOTES="$TEST_HOME/work-notes"
git init -q --bare "$WORK_NOTES_ORIGIN" || fail "could not create work notes origin"
git init -q "$WORK_NOTES" || fail "could not create work notes checkout"
mkdir -p "$WORK_NOTES/impress/weekly" "$WORK_NOTES/impress/memory" || fail "could not create work notes content"
printf 'report\n' > "$WORK_NOTES/impress/weekly/report.html"
printf '# memory\n' > "$WORK_NOTES/impress/memory/MEMORY.md"
printf 'home impress/weekly notes/weekly\nclaude-memory impress/memory code/sample-project\n' > "$WORK_NOTES/links.tsv"
git -C "$WORK_NOTES" add -A &&
  git -C "$WORK_NOTES" -c user.name=Test -c user.email=test@example.invalid commit -q -m notes &&
  git -C "$WORK_NOTES" remote add origin "$WORK_NOTES_ORIGIN" &&
  git -C "$WORK_NOTES" push -q -u origin HEAD >/dev/null 2>&1 || fail "could not publish work notes"
mkdir -p "$TEST_HOME/notes" && ln -s "$WORK_NOTES/impress/weekly" "$TEST_HOME/notes/weekly" || fail "could not link weekly notes"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq 'PASS: Work notes repository is present at ~/work-notes' "$TEST_CASE_DIR/output" || fail "work notes checkout was not recognized"
grep -Fq 'PASS: ~/notes/weekly is linked to work notes' "$TEST_CASE_DIR/output" || fail "linked work notes path was not recognized"
grep -Fq 'PASS: Work notes have no uncommitted changes' "$TEST_CASE_DIR/output" || fail "clean work notes were not recognized"
grep -Fq 'PASS: Work notes are up to date with their remote' "$TEST_CASE_DIR/output" || fail "synced work notes were not recognized"
grep -Fq "WARN: ~/.claude/projects/" "$TEST_CASE_DIR/output" || fail "unlinked Claude memory was not reported"
grep -Fq "memory is not linked to work notes — run install.sh" "$TEST_CASE_DIR/output" || fail "unlinked Claude memory had no guidance"

printf 'draft\n' > "$WORK_NOTES/impress/draft.md"
git -C "$WORK_NOTES" add -A && git -C "$WORK_NOTES" -c user.name=Test -c user.email=test@example.invalid commit -q -m draft || fail "could not commit work notes draft"
printf 'more\n' > "$WORK_NOTES/impress/more.md"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq 'WARN: Work notes have 1 uncommitted change(s)' "$TEST_CASE_DIR/output" || fail "uncommitted work notes were not reported"
grep -Fq 'WARN: Work notes have 1 unpushed commit(s)' "$TEST_CASE_DIR/output" || fail "unpushed work notes were not reported"

# doctor fetches the notes, so a push from another machine shows up as behind.
OTHER_MACHINE="$TEST_CASE_DIR/other-machine"
git clone -q "$WORK_NOTES_ORIGIN" "$OTHER_MACHINE" >/dev/null 2>&1 || fail "could not clone work notes for another machine"
printf 'remote\n' > "$OTHER_MACHINE/impress/remote.md"
git -C "$OTHER_MACHINE" add -A &&
  git -C "$OTHER_MACHINE" -c user.name=Test -c user.email=test@example.invalid commit -q -m remote &&
  git -C "$OTHER_MACHINE" push -q >/dev/null 2>&1 || fail "could not push work notes from another machine"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq 'WARN: Work notes are 1 commit(s) behind their remote — run git pull' "$TEST_CASE_DIR/output" || fail "work notes behind the remote were not reported"
grep -Fq 'WARN: Work notes have 1 unpushed commit(s)' "$TEST_CASE_DIR/output" || fail "diverged work notes lost the unpushed warning"

# A machine-local links.local.tsv replaces the shared entry with the same source.
setup_fixture work-notes-local-override
WORK_NOTES="$TEST_HOME/work-notes"
mkdir -p "$WORK_NOTES/impress/memory" || fail "could not create work notes content"
printf 'claude-memory impress/memory code/shared-path\n' > "$WORK_NOTES/links.tsv"
printf 'claude-memory impress/memory elsewhere/project\n' > "$WORK_NOTES/links.local.tsv"
LOCAL_MEMORY="$TEST_HOME/.claude/projects/$(printf '%s' "$TEST_HOME/elsewhere/project" | sed 's/[^A-Za-z0-9]/-/g')/memory"
mkdir -p "$(dirname "$LOCAL_MEMORY")" && ln -s "$WORK_NOTES/impress/memory" "$LOCAL_MEMORY" || fail "could not link local memory"
run_doctor > "$TEST_CASE_DIR/output" 2>&1
grep -Fq 'memory is linked to work notes (local override)' "$TEST_CASE_DIR/output" || fail "local override link was not recognized"
grep -Fq 'shared-path' "$TEST_CASE_DIR/output" && fail "overridden shared entry was still checked"

# morning: unset, missing, non-Git and ready repositories are each reported.
setup_fixture morning-repos
run_doctor > "$TEST_CASE_DIR/output" 2>&1 || fail "doctor failed without MORNING_REPOS"
grep -Fq 'WARN: morning has no repositories to sync; set MORNING_REPOS' "$TEST_CASE_DIR/output" || fail "unset MORNING_REPOS was not reported"
mkdir -p "$TEST_HOME/code/plain" || fail "could not create plain directory"
git init -q "$TEST_HOME/code/ready" && git -C "$TEST_HOME/code/ready" remote add origin "$TEST_CASE_DIR/ready-origin.git" || fail "could not create ready repository"
git init -q "$TEST_HOME/code/no-origin" || fail "could not create repository without origin"
run_doctor MORNING_REPOS="~/code/ready:$TEST_HOME/code/missing:~/code/plain:~/code/no-origin" > "$TEST_CASE_DIR/output" 2>&1 || fail "doctor failed with MORNING_REPOS"
grep -Fq 'PASS: morning repository ~/code/ready is ready' "$TEST_CASE_DIR/output" || fail "ready morning repository was not accepted"
grep -Fq 'WARN: morning repository ~/code/missing does not exist' "$TEST_CASE_DIR/output" || fail "missing morning repository was not reported"
grep -Fq 'WARN: morning repository ~/code/plain is not a Git repository' "$TEST_CASE_DIR/output" || fail "non-Git morning repository was not reported"
grep -Fq "WARN: morning repository ~/code/no-origin has no 'origin' remote" "$TEST_CASE_DIR/output" || fail "morning repository without origin was not reported"
grep -Fq 'morning has no repositories' "$TEST_CASE_DIR/output" && fail "configured MORNING_REPOS was reported as unset"

echo "doctor regression checks passed"
