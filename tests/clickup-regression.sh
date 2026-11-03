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
printf '%s %s\n' "$method" "$url" >> "$MOCK_DIR/requests"
case "$url" in
  */api/v2/team)
    case "${MOCK_TEAMS:-one}" in
      one) printf '{"teams":[{"id":"777","name":"Only"}]}\n200' ;;
      two) printf '{"teams":[{"id":"111","name":"First"},{"id":"222","name":"Second"}]}\n200' ;;
      bad) printf '{"teams":[{"id":"x/y","name":"Bad"}]}\n200' ;;
    esac
    exit ;;
esac
case "$url" in *'/docs/fail/'*) printf '{}\n404'; exit ;; esac
if [ "$method" != GET ]; then
  printf '%s' "$body" > "$MOCK_DIR/write"
  if [ "$method" = POST ]; then printf '{"id":"new-page"}\n201'
  elif [ "$method" = PUT ] && [[ "$url" == */api/v3/* ]]; then printf '\n200'
  else printf '{}\n200'; fi
  exit
fi
case "$url" in
  *'/docs/doc-1/page_listing?max_page_depth=-1') printf '[{"id":"p1","name":"Root","pages":[{"id":"p2","name":"Child"}]}]\n200' ;;
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
grep -q 'First' "$TMP/out"
"$CLI" snapshot --since 2025-01-01 --list 123 > "$TMP/out"
[ "$(wc -l < "$TMP/out" | tr -d ' ')" = 2 ]
grep -q 'Second' "$TMP/out"
if "$CLI" status abc REVIEW > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 3 ]; fi
[ ! -e "$TMP/write" ]
printf 'hello\nworld\n' | "$CLI" comment abc -
jq -e '.comment_text == "hello\nworld\n"' "$TMP/write" >/dev/null
if "$CLI" task fail > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 2 ]; fi
if grep -q 'synthetic_test_credential' "$TMP/args" "$TMP/out"; then echo 'Credential exposed' >&2; exit 1; fi
export CLICKUP_WORKSPACE_ID=123
"$CLI" doc pages doc-1 > "$TMP/out"
printf 'p1 | Root\n  p2 | Child\n' > "$TMP/expected"
cmp "$TMP/expected" "$TMP/out"
grep -Fq 'GET https://api.clickup.com/api/v3/workspaces/123/docs/doc-1/page_listing?max_page_depth=-1' "$TMP/requests"
printf 'first\nsecond\n' > "$TMP/content.md"
"$CLI" doc page-create doc-1 'New page' "$TMP/content.md" --parent p1 > "$TMP/out"
jq -e '.name == "New page" and .content == "first\nsecond\n" and .content_format == "text/md" and .parent_page_id == "p1"' "$TMP/write" >/dev/null
grep -q '^new-page$' "$TMP/out"
grep -q 'ClickUp UI' "$TMP/out"
grep -Fq 'POST https://api.clickup.com/api/v3/workspaces/123/docs/doc-1/pages' "$TMP/requests"
printf 'stdin\n' | "$CLI" doc page-create doc-1 Title - > "$TMP/out"
jq -e '.content == "stdin\n" and (has("parent_page_id") | not)' "$TMP/write" >/dev/null
printf 'replacement\n' | "$CLI" doc page-update doc-1 p1 - --title Renamed
jq -e '.content == "replacement\n" and .name == "Renamed" and .content_edit_mode == "replace" and .content_format == "text/md"' "$TMP/write" >/dev/null
grep -Fq 'PUT https://api.clickup.com/api/v3/workspaces/123/docs/doc-1/pages/p1' "$TMP/requests"
"$CLI" doc page-update doc-1 p1 "$TMP/content.md"
jq -e '.content == "first\nsecond\n" and (has("name") | not)' "$TMP/write" >/dev/null
for operation in pages page-create page-update; do
  case "$operation" in
    pages) args=(fail) ;;
    page-create) args=(fail Title "$TMP/content.md") ;;
    page-update) args=(fail p1 "$TMP/content.md") ;;
  esac
  if "$CLI" doc "$operation" "${args[@]}" > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 2 ]; fi
done
request_count="$(wc -l < "$TMP/requests")"
for operation in pages page-create page-update; do
  case "$operation" in
    pages) args=('bad/id') ;;
    page-create) args=(doc-1 Title "$TMP/content.md" --parent 'bad/id') ;;
    page-update) args=(doc-1 'bad/id' "$TMP/content.md") ;;
  esac
  if "$CLI" doc "$operation" "${args[@]}" > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 1 ]; fi
done
[ "$(wc -l < "$TMP/requests")" = "$request_count" ]
if CLICKUP_WORKSPACE_ID='bad/id' "$CLI" doc pages doc-1 > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 1 ]; fi
if "$CLI" doc page-create doc-1 > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 1 ]; fi
if "$CLI" doc page-update doc-1 p1 "$TMP/content.md" --append yes > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 1 ]; fi
[ "$(wc -l < "$TMP/requests")" = "$request_count" ]
if grep -q 'synthetic_test_credential' "$TMP/args" "$TMP/out"; then echo 'Credential exposed' >&2; exit 1; fi
# Without CLICKUP_WORKSPACE_ID the workspace is looked up: one usable workspace is used,
# several or none stop the command with the choices listed and no Doc request sent.
unset CLICKUP_WORKSPACE_ID
: > "$TMP/requests"
"$CLI" doc pages doc-1 > "$TMP/out"
cmp "$TMP/expected" "$TMP/out"
grep -Fq 'GET https://api.clickup.com/api/v2/team' "$TMP/requests"
grep -Fq 'GET https://api.clickup.com/api/v3/workspaces/777/docs/doc-1/page_listing' "$TMP/requests"
: > "$TMP/requests"
if MOCK_TEAMS=two "$CLI" doc pages doc-1 > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 1 ]; fi
grep -q '111 | First' "$TMP/out"
grep -q '222 | Second' "$TMP/out"
[ "$(wc -l < "$TMP/requests" | tr -d ' ')" = 1 ]
if MOCK_TEAMS=bad "$CLI" doc pages doc-1 > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 1 ]; fi
grep -q 'Set CLICKUP_WORKSPACE_ID' "$TMP/out"
! grep -q '/v3/' "$TMP/requests"
if grep -q 'synthetic_test_credential' "$TMP/args" "$TMP/out"; then echo 'Credential exposed' >&2; exit 1; fi
printf '%s\n' 'clickup regression: passed'
