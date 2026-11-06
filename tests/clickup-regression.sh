#!/bin/bash
set -euo pipefail
unset CLICKUP_API_TOKEN
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
  if [ "$method" = POST ] && [[ "$url" == */comment ]]; then
    case "${MOCK_POST:-ok}" in
      ok) printf '{"id":"comment-1"}\n200' ;;
      bad) printf '{"id":null}\n200' ;;
      fail) printf '{}\n500' ;;
    esac
  elif [ "$method" = POST ]; then printf '{"id":"new-page"}\n201'
  elif [ "$method" = PUT ] && [[ "$url" == */api/v3/* ]]; then printf '\n200'
  elif [ "$method" = PUT ] && [[ "$url" == */api/v2/task/* ]]; then
    case "${MOCK_ASSIGN_PUT:-ok}" in
      ok) printf '{"assignees":[{"id":7,"username":"Self"}]}\n200' ;;
      preserved) printf '{"assignees":[{"id":8,"username":"Other"},{"id":"7","username":"Self"}]}\n200' ;;
      missing_self) printf '{"assignees":[{"id":8,"username":"Other"}]}\n200' ;;
      dropped_other) printf '{"assignees":[{"id":7,"username":"Self"}]}\n200' ;;
      malformed) printf '{"assignees":[{"id":"bad","username":"Self"}]}\n200' ;;
      no_assignees) printf '{"id":"abc"}\n200' ;;
      fail401) printf '{"err":"synthetic"}\n401' ;;
      fail500) printf '{"err":"synthetic"}\n500' ;;
    esac
  else printf '{}\n200'; fi
  exit
fi
case "$url" in
  */task/abc/comment*)
    case "${MOCK_COMMENTS:-pages}" in
      fail) printf '{}\n500' ;;
      malformed) printf '{"comments":{}}\n200' ;;
      empty) printf '{"comments":[]}\n200' ;;
      long)
        jq -cn '{comments: [range(1;26) | {id: ("long-" + tostring), date: (10000 + . | tostring), user: {username:"Reader"}, comment_text: ("x" * 12000)}]}' | tr -d "\n"; printf '\n200' ;;
      pages|later_fail|repeat)
        case "$url" in
          *'start_id='*)
            case "${MOCK_COMMENTS:-pages}" in
              later_fail) printf '{}\n500'; exit ;;
              repeat) jq -cn '{comments: [range(1;26) | {id: ("comment-" + tostring), date: (10000 + . | tostring), user: {username:"Reader"}, comment_text:"repeat"}]}' | tr -d "\n"; printf '\n200'; exit ;;
            esac ;;
        esac
        case "$url" in
          *'start_id=comment-25&start=10025') printf '{"comments":[{"id":"comment-26","date":"10026","user":{"username":"Reader"},"comment":[{"text":"rich "},{"text":"text\\n"}]}]}\n200' ;;
          *) jq -cn '{comments: [range(1;26) | {id: ("comment-" + tostring), date: (10000 + . | tostring), user: {username:"Reader"}, comment_text: ("text " + tostring)}]}' | tr -d "\n"; printf '\n200' ;;
        esac ;;
    esac ;;
  *'/docs/doc-1/page_listing?max_page_depth=-1') printf '[{"id":"p1","name":"Root","pages":[{"id":"p2","name":"Child"}]}]\n200' ;;
  */task/fail) printf '{}\n404' ;;
  */task/abc)
    case "${MOCK_TASK:-default}" in
      default) assignees='[{"id":7,"username":"Sample"}]' ;;
      empty) assignees='[]' ;;
      self_numeric) assignees='[{"id":7,"username":"Self"}]' ;;
      self_string) assignees='[{"id":"0007","username":"Self"}]' ;;
      other) assignees='[{"id":8,"username":"Other"}]' ;;
      invalid_id) assignees='[{"id":"bad","username":"Bad"}]' ;;
      invalid_large) assignees='[{"id":"2147483648","username":"Large"}]' ;;
      invalid_user) assignees='[{"id":7,"username":null}]' ;;
      missing_assignees) printf '{"id":"abc","name":"Sample","status":{"status":"Open"},"list":{"id":"123","name":"Example"},"url":"https://example.invalid/t/abc"}\n200'; exit ;;
    esac
    printf '{"id":"abc","name":"Sample\001 task","status":{"status":"Open"},"list":{"id":"123","name":"Example"},"url":"https://example.invalid/t/abc","assignees":%s}\n200' "$assignees" ;;
  */list/123) printf '{"name":"Example","statuses":[{"status":"Open","type":"open"},{"status":"Done","type":"closed"},{"status":"Review","type":"custom"},{"status":"review","type":"custom"}]}\n200' ;;
  *'page=0'*) printf '{"tasks":[{"id":"a","name":"First","status":{"status":"Open"},"assignees":[{"id":7,"username":"Sample"}],"date_updated":"1767225600000"}],"last_page":false}\n200' ;;
  *'page=1'*) printf '{"tasks":[{"id":"b","name":"Second","status":{"status":"Done"},"assignees":[],"date_updated":"1767225600000"}],"last_page":true}\n200' ;;
  */user)
    case "${MOCK_USER:-valid}" in
      valid) printf '{"user":{"id":7}}\n200' ;;
      string) printf '{"user":{"id":"0007"}}\n200' ;;
      invalid) printf '{"user":{"id":"seven"}}\n200' ;;
      missing) printf '{"user":{}}\n200' ;;
      denied) printf '{"err":"synthetic"}\n403' ;;
    esac ;;
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
jq -e '.assignees == [{id:"7",username:"Sample"}] and .status == "Open" and .list == "Example" and .url == "https://example.invalid/t/abc"' "$TMP/out" >/dev/null
if ! MOCK_TASK=empty "$CLI" task abc --json > "$TMP/out" 2> "$TMP/err"; then
  echo 'empty-assignees task JSON assertion failed:' >&2
  sed -n '1p' "$TMP/err" >&2
  exit 1
fi
jq -e '.assignees == []' "$TMP/out" >/dev/null
for mode in invalid_id invalid_large invalid_user missing_assignees; do
  if MOCK_TASK="$mode" "$CLI" task abc --json > "$TMP/out" 2> "$TMP/err"; then exit 1; else [ "$?" = 2 ]; fi
  [ ! -s "$TMP/out" ]
  ! grep -q 'Bad\|synthetic' "$TMP/err"
done
: > "$TMP/requests"
MOCK_TASK=empty "$CLI" assign abc --me > "$TMP/out"
grep -Fxq 'Assigned: abc' "$TMP/out"
jq -e '.assignees.add == [7] and .assignees.rem == []' "$TMP/write" >/dev/null
[ "$(awk '$1 == "PUT" && /\/api\/v2\/task\/abc$/ { count++ } END { print count+0 }' "$TMP/requests")" = 1 ]
: > "$TMP/requests"
MOCK_TASK=other MOCK_ASSIGN_PUT=preserved "$CLI" assign abc --me > "$TMP/out"
grep -Fxq 'Assigned: abc' "$TMP/out"
jq -e '.assignees.add == [7] and .assignees.rem == []' "$TMP/write" >/dev/null
: > "$TMP/requests"
MOCK_TASK=self_numeric "$CLI" assign abc --me > "$TMP/out"
grep -Fxq 'Already assigned: abc' "$TMP/out"
[ "$(wc -l < "$TMP/requests" | tr -d ' ')" = 2 ]
: > "$TMP/requests"
MOCK_TASK=self_string MOCK_USER=string "$CLI" assign abc --me > "$TMP/out"
grep -Fxq 'Already assigned: abc' "$TMP/out"
[ "$(wc -l < "$TMP/requests" | tr -d ' ')" = 2 ]
: > "$TMP/requests"
for args in 'abc' 'abc --them' 'abc --me --me' 'bad/id --me'; do
  # Intentional splitting supplies a list of synthetic CLI arguments.
  # shellcheck disable=SC2086
  if "$CLI" assign $args > "$TMP/out" 2> "$TMP/err"; then exit 1; else [ "$?" = 1 ]; fi
done
[ ! -s "$TMP/requests" ]
for mode in invalid missing denied; do
  : > "$TMP/requests"
  if MOCK_TASK=empty MOCK_USER="$mode" "$CLI" assign abc --me > "$TMP/out" 2> "$TMP/err"; then exit 1; else [ "$?" = 2 ]; fi
  [ ! -s "$TMP/out" ]
  [ "$(awk '$1 == "PUT" { count++ } END { print count+0 }' "$TMP/requests")" = 0 ]
done
for mode in missing_self dropped_other malformed no_assignees fail401 fail500; do
  : > "$TMP/requests"
  task_mode=empty; [ "$mode" != dropped_other ] || task_mode=other
  if MOCK_TASK="$task_mode" MOCK_ASSIGN_PUT="$mode" "$CLI" assign abc --me > "$TMP/out" 2> "$TMP/err"; then exit 1; else [ "$?" = 2 ]; fi
  [ ! -s "$TMP/out" ]
  grep -qi 'check the task before retrying' "$TMP/err"
  [ "$(awk '$1 == "PUT" { count++ } END { print count+0 }' "$TMP/requests")" = 1 ]
  ! grep -q 'synthetic_test_credential\|"err"\|synthetic' "$TMP/out" "$TMP/err"
done
"$CLI" open --list 123 --assignee me > "$TMP/out"
[ "$(wc -l < "$TMP/out" | tr -d ' ')" = 1 ]
grep -q 'First' "$TMP/out"
"$CLI" snapshot --since 2025-01-01 --list 123 > "$TMP/out"
[ "$(wc -l < "$TMP/out" | tr -d ' ')" = 2 ]
grep -q 'Second' "$TMP/out"
# Each write assertion starts without artifacts from earlier assignment cases.
rm -f "$TMP/write"
if "$CLI" status abc REVIEW > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 3 ]; fi
[ ! -e "$TMP/write" ]
printf 'hello\nworld\n' | "$CLI" comment abc - > "$TMP/out"
grep -Fxq 'Comment posted: comment-1' "$TMP/out"
jq -e '.comment_text == "hello\nworld\n"' "$TMP/write" >/dev/null
# Reads use normalized output, bounded pages, and safe cursor parameters.
: > "$TMP/requests"
"$CLI" comments 'https://example.invalid/t/abc/?view=1#section' --json > "$TMP/out"
jq -e 'length == 25 and .[0] == {id:"comment-1",author:"Reader",date:"10001",text:"text 1"}' "$TMP/out" >/dev/null
[ "$(wc -l < "$TMP/requests" | tr -d ' ')" = 1 ]
: > "$TMP/requests"
"$CLI" comments abc --limit 26 --json > "$TMP/out"
jq -e 'length == 26 and .[25].text == "rich text\n"' "$TMP/out" >/dev/null
grep -Fq '?start_id=comment-25&start=10025' "$TMP/requests"
[ "$(wc -l < "$TMP/requests" | tr -d ' ')" = 2 ]
"$CLI" comments abc --limit 1 > "$TMP/out"
grep -Fxq 'id: comment-1' "$TMP/out"
MOCK_COMMENTS=long "$CLI" comments abc --json > "$TMP/out"
jq -e 'length == 25 and all(.[]; (.text | length) == 12000)' "$TMP/out" >/dev/null
MOCK_COMMENTS=empty "$CLI" comments abc --json > "$TMP/out"
jq -e '. == []' "$TMP/out" >/dev/null
for mode in fail malformed later_fail repeat; do
  if MOCK_COMMENTS="$mode" "$CLI" comments abc --limit 51 > "$TMP/out" 2> "$TMP/err"; then exit 1; else [ "$?" = 2 ]; fi
  [ ! -s "$TMP/out" ]
done
if MOCK_COMMENTS=repeat "$CLI" comments abc --limit 50 > "$TMP/out" 2> "$TMP/err"; then exit 1; else [ "$?" = 2 ]; fi
[ ! -s "$TMP/out" ]
: > "$TMP/requests"
for args in '--limit 0' '--limit nope' '--limit 1000000' '--json --json' '--limit 1 --limit 2' '--unknown'; do
  # Intentional splitting supplies a list of synthetic CLI arguments.
  # shellcheck disable=SC2086
  if "$CLI" comments abc $args > "$TMP/out" 2>&1; then exit 1; else [ "$?" = 1 ]; fi
done
[ ! -s "$TMP/requests" ]
: > "$TMP/requests"
if printf 'test' | MOCK_POST=bad "$CLI" comment abc - > "$TMP/out" 2> "$TMP/err"; then exit 1; else [ "$?" = 2 ]; fi
[ ! -s "$TMP/out" ]
grep -Fq 'may have been posted' "$TMP/err"
[ "$(wc -l < "$TMP/requests" | tr -d ' ')" = 1 ]
if printf 'test' | MOCK_POST=fail "$CLI" comment abc - > "$TMP/out" 2> "$TMP/err"; then exit 1; else [ "$?" = 2 ]; fi
[ ! -s "$TMP/out" ]
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
