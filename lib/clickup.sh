# shellcheck shell=bash
# ClickUp API helpers. Source after lib/http.sh and load CLICKUP_API_TOKEN on demand.
clickup_request() {
  local body expected=object
  if [ "${1:-}" = --array ]; then expected=array; shift; fi
  body="$(http_request -H "Authorization: ${CLICKUP_API_TOKEN}" "$@")" || return 1
  body="$(printf '%s' "$body" | LC_ALL=C tr -d '\000-\037')"
  if ! printf '%s' "$body" | jq -e --arg expected "$expected" 'type == $expected' >/dev/null 2>&1; then
    echo 'ClickUp returned invalid JSON.' >&2
    return 1
  fi
  printf '%s\n' "$body"
}

clickup_task() { clickup_request "https://api.clickup.com/api/v2/task/$1"; }
clickup_list() { clickup_request "https://api.clickup.com/api/v2/list/$1"; }
clickup_user() { clickup_request 'https://api.clickup.com/api/v2/user' | jq -er '.user.id | select(. != null) | tostring'; }
clickup_resolve_status() {
  printf '%s' "$1" | jq -c --arg name "$2" '[.statuses[] | select(.status | ascii_downcase == ($name | ascii_downcase)) | .status]'
}
clickup_update_status() {
  local body
  body="$(jq -n --arg status "$2" '{status:$status}')" || return 1
  clickup_request -X PUT -H 'Content-Type: application/json' -d "$body" "https://api.clickup.com/api/v2/task/$1" >/dev/null
}
clickup_comment() {
  local body
  body="$(jq -n --arg comment "$2" '{comment_text:$comment}')" || return 1
  clickup_request -X POST -H 'Content-Type: application/json' -d "$body" "https://api.clickup.com/api/v2/task/$1/comment"
}
# Return one normalized array only after every required page has succeeded.
clickup_comments() {
  local id="$1" limit="$2" result='[]' response page count cursor previous='' seen='|' url
  while :; do
    url="https://api.clickup.com/api/v2/task/${id}/comment"
    [ -z "$previous" ] || url="${url}?${previous}"
    response="$(clickup_request "$url")" || return 1
    page="$(printf '%s' "$response" | jq -ce '
      if (.comments | type) != "array" then error("invalid comments") else .comments end |
      map(if type != "object" or ((.id | type) != "string" and (.id | type) != "number") or
             ((.id | tostring) | test("^[A-Za-z0-9_-]+$") | not) or
             ((.date | type) != "string" and (.date | type) != "number") or
             ((.date | tostring) | test("^[0-9]+$") | not) or
             (.user.username | type) != "string" then error("invalid comment")
          else {id: (.id | tostring), author: .user.username, date: (.date | tostring),
                text: (if (.comment_text | type) == "string" then .comment_text
                       elif (.comment | type) == "array" and all(.comment[]; (.text | type) == "string")
                       then [.comment[].text] | join("") else error("invalid text") end)} end)' 2>/dev/null)" || return 1
    count="$(printf '%s' "$page" | jq 'length')" || return 1
    result="$(printf '%s\n%s\n' "$result" "$page" | jq -cs --argjson limit "$limit" '(.[0] + .[1])[:$limit]')" || return 1
    if [ "$count" -gt 0 ]; then
      cursor="$(printf '%s' "$page" | jq -r 'last | "start_id=\(.id)&start=\(.date)"')" || return 1
      case "$seen" in *"|$cursor|"*) return 1 ;; esac
      seen="${seen}${cursor}|"
      previous="$cursor"
    fi
    [ "$(printf '%s' "$result" | jq 'length')" -lt "$limit" ] || break
    [ "$count" -eq 25 ] || break
  done
  printf '%s\n' "$result"
}
clickup_tasks() {
  local list="$1" page=0 response count last
  while :; do
    response="$(clickup_request "https://api.clickup.com/api/v2/list/${list}/task?page=${page}&include_closed=true")" || return 1
    if ! printf '%s' "$response" | jq -e '.tasks | type == "array"' >/dev/null; then
      echo 'ClickUp returned an invalid task list.' >&2
      return 1
    fi
    printf '%s\n' "$response" | jq -c '.tasks[]' || return 1
    count="$(printf '%s' "$response" | jq '.tasks | length')"
    last="$(printf '%s' "$response" | jq -r '.last_page // false')"
    [ "$last" = true ] && break
    [ "$count" -eq 0 ] && break
    page=$((page + 1))
  done
}

# Prints a JSON array of {id, name} for the workspaces the token can use. Entries with an
# unusable id or name are dropped, so an empty array means "none usable".
clickup_workspaces() {
  clickup_request "https://api.clickup.com/api/v2/team" | jq -c '
    [(.teams // [])[] | select((.id | type == "string") and (.id | test("^[A-Za-z0-9_-]+$")) and (.name | type == "string")) | {id, name}]'
}
clickup_doc_pages() {
  clickup_request --array "https://api.clickup.com/api/v3/workspaces/$1/docs/$2/page_listing?max_page_depth=-1"
}
clickup_doc_create() {
  local body
  body="$(jq -n --arg name "$3" --arg content "$4" --arg parent "$5" \
    '{name:$name, content:$content, content_format:"text/md"} + (if $parent == "" then {} else {parent_page_id:$parent} end)')" || return 1
  clickup_request -X POST -H 'Content-Type: application/json' -d "$body" "https://api.clickup.com/api/v3/workspaces/$1/docs/$2/pages"
}
clickup_doc_update() {
  local body
  body="$(jq -n --arg content "$4" --arg title "$5" --argjson has_title "$6" \
    '{content:$content, content_format:"text/md", content_edit_mode:"replace"} + (if $has_title then {name:$title} else {} end)')" || return 1
  # ClickUp answers a successful page edit with an empty body, so only the HTTP status counts.
  http_request -H "Authorization: ${CLICKUP_API_TOKEN}" -X PUT -H 'Content-Type: application/json' -d "$body" \
    "https://api.clickup.com/api/v3/workspaces/$1/docs/$2/pages/$3" >/dev/null
}
