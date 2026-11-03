#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/repo with spaces/scripts" "$TMP/bin"
cp "$ROOT/scripts/cmds" "$TMP/repo with spaces/scripts/"
CLI="$TMP/repo with spaces/scripts/cmds"
export HOME="$TMP/home" PATH="$TMP/bin:$PATH" TEST_DIR="$TMP"
cat > "$TMP/repo with spaces/scripts/ado-rest" <<'SCRIPT'
#!/bin/bash
# Description: Read "quoted" paths\names
printf 'executed\n' > "$TEST_DIR/executed"
SCRIPT
cat > "$TMP/repo with spaces/scripts/config-git" <<'SCRIPT'
#!/bin/bash
# Description: Configure identity
printf 'executed\n' > "$TEST_DIR/executed"
SCRIPT
cat > "$TMP/repo with spaces/scripts/no description" <<'SCRIPT'
#!/bin/bash
# not metadata
# Description: Must not be displayed
SCRIPT
printf '#!/bin/bash\n# Description: invalid\001text\n' > "$TMP/repo with spaces/scripts/invalid"
printf '#!/bin/bash\n# Description: Hidden\n' > "$TMP/repo with spaces/scripts/not-executable"
printf '#!/bin/bash\n# Description: Hidden\n' > "$TMP/repo with spaces/scripts/$(printf 'bad\nname')"
chmod +x "$TMP/repo with spaces/scripts/ado-rest" "$TMP/repo with spaces/scripts/config-git" "$TMP/repo with spaces/scripts/no description" "$TMP/repo with spaces/scripts/invalid" "$TMP/repo with spaces/scripts/$(printf 'bad\nname')"
cat > "$TMP/bin/fzf" <<'SCRIPT'
#!/bin/bash
printf 'used\n' > "$TEST_DIR/fzf-used"
cat >/dev/null
SCRIPT
chmod +x "$TMP/bin/fzf"
printf 'fixture config\n' > "$HOME/.gitconfig"
cp "$HOME/.gitconfig" "$TMP/config-before"
"$CLI" --list </dev/null > "$TMP/list"
"$CLI" --list </dev/null > "$TMP/list-again"
cmp "$TMP/list" "$TMP/list-again"
"$CLI" --json </dev/null > "$TMP/json"
"$CLI" --json </dev/null > "$TMP/json-again"
cmp "$TMP/json" "$TMP/json-again"
jq -e 'map(.name) == ["ado-rest", "cmds", "config-git", "invalid", "no description"] and .[0].description == "Read \"quoted\" paths\\names" and .[3].description == "(no description)" and .[4].description == "(no description)"' "$TMP/json" >/dev/null
[ "$(wc -l < "$TMP/list" | tr -d ' ')" = 5 ]
! grep -q 'Must not be displayed\|Hidden' "$TMP/list"
[ ! -e "$TMP/executed" ] && [ ! -e "$TMP/fzf-used" ]
cmp "$HOME/.gitconfig" "$TMP/config-before"
"$CLI" --help | grep -q -- '--json'
if "$CLI" --list --json > /dev/null 2>&1; then exit 1; fi
if "$CLI" --unknown > /dev/null 2>&1; then exit 1; fi
"$CLI" </dev/null > /dev/null
[ -e "$TMP/fzf-used" ] && [ ! -e "$TMP/executed" ]
mkdir -p "$TMP/fallback-bin"
ln -s "$(command -v realpath)" "$TMP/fallback-bin/realpath"
ln -s "$(command -v dirname)" "$TMP/fallback-bin/dirname"
cat > "$TMP/fallback-bin/stty" <<'SCRIPT'
#!/bin/bash
if [ "${1:-}" = -g ]; then printf 'fixture\n'; fi
SCRIPT
cat > "$TMP/fallback-bin/tput" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
chmod +x "$TMP/fallback-bin/stty" "$TMP/fallback-bin/tput"
printf q | PATH="$TMP/fallback-bin" "$CLI" > "$TMP/menu"
grep -q 'Scripts' "$TMP/menu"
[ ! -e "$TMP/executed" ]
mkdir -p "$TMP/empty"
cp "$CLI" "$TMP/empty/cmds"
chmod -x "$TMP/empty/cmds"
[ "$(/bin/bash "$TMP/empty/cmds" --json </dev/null)" = '[]' ]
[ -z "$(/bin/bash "$TMP/empty/cmds" --list </dev/null)" ]
printf '%s\n' 'cmds regression: passed'
