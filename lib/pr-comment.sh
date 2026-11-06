# shellcheck shell=bash
# Sourced by scripts/pr; post one top-level Azure DevOps thread.

if [ "$#" -ne 2 ] || [[ ! "${1:-}" =~ ^[0-9]+$ ]] || [[ ! "${1:-}" =~ [1-9] ]]; then
  echo 'Usage: pr comment <positive-id> <file|->' >&2
  exit 2
fi
pr_id="$1"
input="$2"
for cmd in jq curl iconv; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ '$cmd' is required." >&2
    exit 1
  fi
done
if [ "$input" != - ] && { [ ! -f "$input" ] || [ ! -r "$input" ]; }; then
  echo '❌ Comment file is missing or unreadable.' >&2
  exit 2
fi
if [ "$input" = - ] && [ -t 0 ]; then
  echo '❌ Pipe comment text to stdin.' >&2
  exit 2
fi
umask 077
comment_tmp="$(mktemp -d "${TMPDIR:-/tmp}/pr-comment.XXXXXX")" || exit 1
trap 'rm -rf "$comment_tmp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$input" = - ]; then
  cat > "$comment_tmp/text" || { echo '❌ Could not read comment.' >&2; exit 2; }
else
  cat < "$input" > "$comment_tmp/text" || { echo '❌ Could not read comment.' >&2; exit 2; }
fi
if [ ! -s "$comment_tmp/text" ] || ! iconv -f UTF-8 -t UTF-8 < "$comment_tmp/text" > /dev/null 2>&1; then
  echo '❌ Comment must be nonempty, valid UTF-8.' >&2
  exit 2
fi
if ! jq -n --rawfile text "$comment_tmp/text" \
  '{comments: [{parentCommentId: 0, content: $text, commentType: 1}], status: 1}' > "$comment_tmp/body"; then
  echo '❌ Could not prepare comment.' >&2
  exit 1
fi
source "$PR_ROOT/lib/azure-devops.sh"
source "$PR_ROOT/lib/http.sh"
source "$PR_ROOT/lib/local-env.sh"
if ! ado_resolve_repo_context; then
  echo "❌ ${ADO_CONTEXT_ERROR}" >&2
  exit 1
fi
if ! ado_get_auth_header; then
  echo "❌ ${ADO_AUTH_ERROR}" >&2
  exit 1
fi
url="https://dev.azure.com/${ADO_ORG_PATH}/${ADO_PROJECT_PATH}/_apis/git/repositories/${ADO_REPO_PATH}/pullrequests/${pr_id}/threads?api-version=7.1"
# fd 3 belongs to http_request's private authentication header pipe.
if ! response="$(http_request -X POST -H "$ADO_AUTH_HEADER" -H 'Content-Type: application/json' "$url" --data-binary @/dev/fd/4 4< "$comment_tmp/body" 2>/dev/null)"; then
  echo '❌ Comment request failed or its outcome is uncertain. Inspect the PR before retrying.' >&2
  exit 1
fi
if ! thread_id="$(printf '%s' "$response" | jq -ser 'if length == 1 and (.[0].id | type == "number" and . > 0 and floor == .) then .[0].id | tostring | select(test("^[0-9]+$")) else empty end' 2>/dev/null)" || [ -z "$thread_id" ]; then
  echo '❌ Comment response was invalid or incomplete. Inspect the PR before retrying.' >&2
  exit 1
fi
printf '%s\n' "$thread_id"
