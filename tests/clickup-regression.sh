#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/repo/scripts" "$TMP/repo/lib" "$TMP/bin"
cp "$ROOT/scripts/clickup" "$TMP/repo/scripts/"
cp "$ROOT/lib/"{clickup,http,local-env}.sh "$TMP/repo/lib/"
cat > "$TMP/bin/curl" <<'MOCK'
#!/bin/bash
set -eu
printf '%s\n' "$@" >> "$MOCK_DIR/args"
url=''; method=GET; body=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [ "$method" != GET ]; then printf '%s' "$body" > "$MOCK_DIR/write"; printf '{}\n200'; exit; fi
case "$url" in
  */task/fail) printf '{}\n404' ;;
  */task/abc) printf '{"id":"abc","name":"Sample\001 task","status":{"status":"Open"},"list":{"id":"123","name":"Example"},"url":"https://example.invalid/t/abc"}\n200' ;;
  */list/123) printf '{"name":"Example","statuses":[{"status":"Open","type":"open"},{"status":"Done","type":"closed"},{"status":"Review","type":"custom"},{"status":"review","type":"custom"}]}\n200' ;;
  *'page=0'*) printf '{"tasks":[{"id":"a","name":"First","status":{"status":"Open"},"assignees":[{"id":7,"username":"Sample"}],"date_updated":"1767225600000"}],"last_page":false}\n200' ;;
  *'page=1'*) printf '{"tasks":[{"id":"b","name":"Second","status":{"status":"Done"},"assignees":[],"date_updated":"1767225600000"}],"last_page":true}\n200' ;;
  */user) printf '{"user":{"id":7}}\n200' ;;
  *) printf '{}\n404' ;;
esac
MOCK
chmod +x "$TMP/bin/curl"
export HOME="$TMP/home" PATH="$TMP/bin:$PATH" MOCK_DIR="$TMP"
# The fixture contains only a synthetic credential and never touches a real home.
mkdir -p "$TMP/repo/alias"
printf '%s\n' 'CLICKUP_API_TOKEN=synthetic_test_credential' > "$TMP/repo/alias/.env"
CLI="$TMP/repo/scripts/clickup"
"$CLI" task 'https://example.invalid/t/abc?view=1' --json > "$TMP/out"
jq -e '.title == "Sample task" and .id == "abc"' "$TMP/out" >/dev/null
"$CLI" open --list 123 --assignee me > "$TMP/out"
[ "$(wc -l < "$TMP/out" | tr -d ' ')" = 1 ]
rg -q 'First' "$TMP/out"
"$CLI" snapshot --since 2025-01-01 --list 123 > "$TMP/out"
[ "$(wc -l < "$TMP/out" | tr -d ' ')" = 2 ]
rg -q 'Second' "$TMP/out"
if "$CLI" status abc REVIEW > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 3 ]; fi
[ ! -e "$TMP/write" ]
printf 'hello\nworld\n' | "$CLI" comment abc -
jq -e '.comment_text == "hello\nworld\n"' "$TMP/write" >/dev/null
if "$CLI" task fail > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 2 ]; fi
if rg -q 'synthetic_test_credential' "$TMP/args" "$TMP/out"; then echo 'Credential exposed' >&2; exit 1; fi
printf '%s\n' 'clickup regression: passed'
