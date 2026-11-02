# shellcheck shell=bash
# ClickUp API helpers. Source after lib/http.sh and load CLICKUP_API_TOKEN on demand.
clickup_request() {
  local body
  body="$(http_request -H "Authorization: ${CLICKUP_API_TOKEN}" "$@")" || return 1
  body="$(printf '%s' "$body" | LC_ALL=C tr -d '\000-\037')"
  if ! printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
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
  clickup_request -X POST -H 'Content-Type: application/json' -d "$body" "https://api.clickup.com/api/v2/task/$1/comment" >/dev/null
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
