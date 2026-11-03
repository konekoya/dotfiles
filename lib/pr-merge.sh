# shellcheck shell=bash
# Sourced by scripts/pr; command-specific implementation.
# Usage: pr merge [ID] [--json] [--waive-checklist]
#        pr merge ID --requeue-expired
#        pr merge ID --execute --head SHA [--waive-checklist] [--interval SECONDS] [--timeout SECONDS] [--json]
#
# The default is a read-only preview (GET requests only). --execute and --requeue-expired are
# the only paths that send a write. Readiness fails closed: any missing or unrecognised API
# field is reported as unknown_policy_state, never as ready.

set -euo pipefail

for cmd in jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ '$cmd' is required. Install with: brew install $cmd" >&2
    exit 1
  fi
done

MERGE_USAGE="Usage: pr merge [ID] [--json] [--waive-checklist]
       pr merge ID --requeue-expired
       pr merge ID --execute --head SHA [--waive-checklist] [--interval SECONDS] [--timeout SECONDS] [--json]"

JSON=false
EXECUTE=false
REQUEUE=false
WAIVE=false
HEAD_ARG=""
INTERVAL=5
TIMEOUT=300
PR_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --execute) EXECUTE=true; shift ;;
    --requeue-expired) REQUEUE=true; shift ;;
    --waive-checklist) WAIVE=true; shift ;;
    --head)
      if [ $# -lt 2 ] || [[ ! "$2" =~ ^[0-9a-fA-F]{8,40}$ ]]; then
        echo "❌ --head requires a commit id (8 to 40 hex characters) from the preview." >&2
        exit 2
      fi
      HEAD_ARG="$2"; shift 2
      ;;
    --interval|--timeout)
      if [ $# -lt 2 ] || [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "❌ $1 requires a positive number of seconds." >&2
        exit 2
      fi
      if [ "$1" = --interval ]; then INTERVAL="$2"; else TIMEOUT="$2"; fi
      shift 2
      ;;
    *)
      if [[ ! "$1" =~ ^[1-9][0-9]*$ ]] || [ -n "$PR_ID" ]; then
        echo "$MERGE_USAGE" >&2
        exit 2
      fi
      PR_ID="$1"; shift
      ;;
  esac
done

if [ "$EXECUTE" = true ] && [ "$REQUEUE" = true ]; then
  echo "❌ --execute and --requeue-expired cannot be combined. Requeue first, wait for the builds, then re-run the preview." >&2
  exit 2
fi
if [ "$JSON" = true ] && [ "$REQUEUE" = true ]; then
  echo "❌ --json cannot be combined with --requeue-expired." >&2
  exit 2
fi
if [ "$WAIVE" = true ] && [ "$REQUEUE" = true ]; then
  echo "❌ --waive-checklist applies to the preview and --execute only." >&2
  exit 2
fi
if { [ "$EXECUTE" = true ] || [ "$REQUEUE" = true ]; } && [ -z "$PR_ID" ]; then
  echo "❌ A write needs an explicit PR ID: pr merge <ID> ..." >&2
  exit 2
fi
if [ "$EXECUTE" = true ] && [ -z "$HEAD_ARG" ]; then
  echo "❌ --execute requires --head <commit> copied from the preview." >&2
  exit 2
fi
if [ -n "$HEAD_ARG" ] && [ "$EXECUTE" != true ]; then
  echo "❌ --head is only used with --execute." >&2
  exit 2
fi

SCRIPT_DIR="$PR_ROOT/scripts"
source "$SCRIPT_DIR/../lib/azure-devops.sh"
source "$SCRIPT_DIR/../lib/http.sh"
source "$SCRIPT_DIR/../lib/local-env.sh"

# ── Resolve Azure DevOps repository context ──────────────────────────
if ! ado_resolve_repo_context; then
  echo "❌ ${ADO_CONTEXT_ERROR}" >&2
  exit 1
fi
ORG_PATH="$ADO_ORG_PATH"
PROJECT="$ADO_PROJECT"
PROJECT_PATH="$ADO_PROJECT_PATH"
REPO_NAME="$ADO_REPO"
REPO_PATH="$ADO_REPO_PATH"

# ── Auth ─────────────────────────────────────────────────────────────
if ! ado_get_auth_header; then
  echo "❌ ${ADO_AUTH_ERROR}" >&2
  exit 1
fi
AUTH_HEADER="$ADO_AUTH_HEADER"

API_BASE="https://dev.azure.com/${ORG_PATH}/${PROJECT_PATH}"

# ── Resolve PR ID for the current branch (preview only) ──────────────
if [ -z "$PR_ID" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
    echo "❌ Not on a named branch. Pass an ID: pr merge <ID>" >&2
    exit 1
  fi
  BRANCH_ENCODED=$(jq -rn --arg b "$BRANCH" '$b | @uri')
  PR_ID=$(http_json -H "$AUTH_HEADER" \
    "${API_BASE}/_apis/git/repositories/${REPO_PATH}/pullrequests?searchCriteria.sourceRefName=refs/heads/${BRANCH_ENCODED}&searchCriteria.status=active&api-version=7.1" \
    | jq -r '.value[0].pullRequestId // empty')
  if [ -z "$PR_ID" ]; then
    echo "❌ No open PR found for branch '${BRANCH}'. Pass an ID: pr merge <ID>" >&2
    exit 1
  fi
  if [[ ! "$PR_ID" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ The PR lookup returned an unexpected id." >&2
    exit 1
  fi
fi

PR_URL="${API_BASE}/_apis/git/repositories/${REPO_PATH}/pullrequests/${PR_ID}?api-version=7.1"

# ── Readiness program ────────────────────────────────────────────────
# Input: {pr, evals, builds}; evals/builds are null when they were not fetched. Output:
# {pub, text, message, requeue}. `pub` is the allowlisted --json view (enums, counts, commit ids and
# tool-defined names only). `text` is the human preview; every API-supplied string in it passes
# through clean (ANSI/control characters removed, URLs redacted). `message` is the raw merge message.
# Every decision defaults to blocked: a missing or unrecognised field adds unknown_policy_state.
read -r -d '' ASSESS_JQ <<'EOF' || true
def g(f): try f catch null;
def clean:
  if type == "string" then
    gsub("\u001b\\][^\u0007\u001b]*(\u0007|\u001b\\\\)?"; "")
    | gsub("\u001b\\[[0-9;?]*[ -/]*[@-~]"; "")
    | explode
    | map(if . == 9 then 32 else . end)
    | map(select(. >= 32 and . != 127 and (. < 128 or . > 159)))
    | implode
    | gsub("https?://[^\\s]*"; "[url]"; "i")
    | .[0:200]
  else "" end;
def r($code; $subject; $msg): {code: $code, subject: $subject, message: $msg};
def unk($f): r("unknown_policy_state"; $f; "\($f) is missing or unrecognised.");
def hex40: type == "string" and test("^[0-9a-fA-F]{40}$");
def sh8: if type == "string" then .[0:8] else "?" end;
def enum($allowed): . as $v | if any($allowed[]; . == $v) then $v else "unknown" end;
def known_status: ["approved", "rejected", "queued", "running", "broken", "notApplicable"];
def kind_of($n):
  if $n == "Build" then "build"
  elif $n == "Minimum number of reviewers" then "minimumReviewers"
  elif $n == "Required reviewers" then "requiredReviewers"
  elif $n == "Comment requirements" then "commentResolution"
  elif $n == "Work item linking" then "workItemLinking"
  elif $n == "Require a merge strategy" then "mergeStrategy"
  else "other" end;
def dedupe: reduce .[] as $x ([]; if any(.[]; .code == $x.code and .subject == $x.subject) then . else . + [$x] end);

(.pr | if type == "object" then . else {} end) as $p
| .evals as $ev
| .builds as $bl
| "<!-- risk-assessment:start -->" as $SM
| "<!-- risk-assessment:end -->" as $EM

# ── pull request fields ──
| $p.status as $st
| (if $st == "active" then []
   elif $st == "completed" or $st == "abandoned" then [r("not_active"; null; "PR is \($st), not active.")]
   else [unk("status")] end) as $r_status
| (if $p.isDraft == true then [r("draft"; null; "PR is a draft.")]
   elif $p.isDraft == false then []
   else [unk("isDraft")] end) as $r_draft
| $p.mergeStatus as $ms
| (if $ms == "succeeded" then []
   elif $ms == "conflicts" then [r("conflict"; null; "PR has a merge conflict.")]
   elif $ms == "queued" or $ms == "notSet" or $ms == "failure" or $ms == "rejectedByPolicy" then [r("merge_status"; null; "Merge status is \($ms), not succeeded.")]
   else [unk("mergeStatus")] end) as $r_merge
| g($p.lastMergeSourceCommit.commitId) as $head0
| (if ($head0 | hex40) then ($head0 | ascii_downcase) else null end) as $head
| g($p.lastMergeCommit.commitId) as $mc0
| (if ($mc0 | hex40) then ($mc0 | ascii_downcase) else null end) as $mc
| (if $head == null then [unk("lastMergeSourceCommit")] else [] end) as $r_head
| (if $mc0 == null then (if $ms == "succeeded" then [unk("lastMergeCommit")] else [] end)
   elif $mc == null then [unk("lastMergeCommit")]
   else [] end) as $r_mc
| $p.title as $title
| (if ($title | type) == "string" and ($title | length) > 0 then [] else [unk("title")] end) as $r_title
| (if ($title | type) == "string" then $title else "" end) as $t

# ── approvals ──
| (if ($p.reviewers | type) == "array" then $p.reviewers elif $p.reviewers == null then [] else null end) as $rv
| (if $rv == null then [unk("reviewers")] else [] end) as $r_rvfmt
| (($rv // []) | map(if type == "object" then . else {vote: "bad"} end)) as $rvs
| ($rvs | map(. as $x | select(((.vote | type) != "number") or (any([-10, -5, 0, 5, 10][]; . == $x.vote) | not)))) as $badvotes
| (if ($badvotes | length) > 0 then [unk("reviewer.vote")] else [] end) as $r_vote
| ($rvs | map(select(.isContainer != true))) as $people
| ($people | map(select(.vote == 5 or .vote == 10)) | length) as $approved
| ($rvs | map(select(.vote == -5 or .vote == -10)) | length) as $rejected
| ($people | map(select(.isRequired == true and ((.vote | type) != "number" or .vote < 5))) | length) as $reqPending
| (if $rejected > 0 then [r("approval_rejected"; null; "A reviewer voted reject or wait-for-author.")] else [] end) as $r_rej
| (if $approved == 0 or $reqPending > 0 then [r("approval_missing"; null; "Required approval missing: no approving vote (10 or 5), or a required reviewer has not approved.")] else [] end) as $r_appr

# ── policy evaluations ──
| (if ($ev | type) == "object" and ($ev.value | type) == "array" then $ev.value else null end) as $evs
| (if $evs == null then [unk("policyEvaluations")] else [] end) as $r_evfmt
| (($evs // []) | map(
    (if type == "object" then . else {} end) as $x
    | {x: $x,
       tname: g($x.configuration.type.displayName),
       blocking: g($x.configuration.isBlocking),
       enabled: g($x.configuration.isEnabled),
       status: g($x.status)}
    | .kind = (if (.tname | type) == "string" then kind_of(.tname) else "other" end)
    | .statusKnown = (.status as $s | any(known_status[]; . == $s))
    | .valid = ((.tname | type) == "string" and (.blocking | type) == "boolean" and .statusKnown)
    | .relevant = (.valid and .blocking == true and .enabled != false and .status != "notApplicable")
  )) as $N
| ($N | map(select(.valid | not) | if (.tname | type) != "string" then unk("policy.type") elif (.blocking | type) != "boolean" then unk("policy.isBlocking") else unk("policy.status") end)) as $r_evinv
| ($N | map(select(.relevant and .kind != "build" and .status != "approved")
    | r("policy_not_approved"; .kind; "Required policy \"\(.tname | clean)\" is \(.status).")) ) as $r_pol

# ── required builds ──
| ($N | map(select(.relevant and .kind == "build"))) as $RB
| (if ($RB | length) > 0 and (($bl | type) != "object" or ($bl.value | type) != "array") then [unk("builds")] else [] end) as $r_blfmt
| (if ($bl | type) == "object" and ($bl.value | type) == "array" then $bl.value else [] end) as $BL
| ($RB | map(
    . as $b
    | g($b.x.configuration.settings.buildDefinitionId) as $did
    | (if ($did | type) == "number" then ($BL | map(select(type == "object" and g(.definition.id) == $did)) | .[0]) else null end) as $nb
    | (if ($did | type) == "number" then (g($nb.definition.name) | clean) else "" end) as $nm
    | (if $nm == "" then "definition:\($did)" else $nm end) as $name
    | ("definition:\($did)") as $subj
    | (g($b.x.context.isExpired) == true) as $exp
    | g($nb.status) as $bst
    | g($nb.result) as $bres
    | g($nb.sourceVersion) as $bsv
    | (if ($bsv | hex40) then ($bsv | ascii_downcase) else null end) as $sv
    | (if ($did | type) != "number" then {state: "unknown", reason: unk("build.definitionId")}
       elif $exp then {state: "expired", reason: r("build_expired"; $subj; "Required build \"\($name)\" is expired. Requeue with --requeue-expired.")}
       elif $nb == null then {state: "missing", reason: r("build_missing"; $subj; "No build found for required pipeline \"\($name)\".")}
       elif $bst == "completed" then
         (if ($bres | type) != "string" then {state: "unknown", reason: unk("build.result")}
          elif $bres == "succeeded" then
            (if $sv == null then {state: "unknown", reason: unk("build.sourceVersion")}
             elif $mc == null then {state: "unknown", reason: null}
             elif $sv == $mc then {state: "succeeded", reason: null}
             else {state: "succeeded", reason: r("build_stale"; $subj; "Required build \"\($name)\" ran on \($sv | sh8), not the current merge commit \($mc | sh8).")} end)
          else {state: "failed", reason: r("build_failed"; $subj; "Required build \"\($name)\" did not succeed (\($bres | clean)).")} end)
       elif any(["notStarted", "inProgress", "postponed", "cancelling"][]; . == $bst) then {state: "pending", reason: r("build_pending"; $subj; "Required build \"\($name)\" is still running.")}
       else {state: "unknown", reason: unk("build.status")} end) as $res
    | {name: $name,
       definitionId: (if ($did | type) == "number" then $did else null end),
       state: $res.state,
       current: ($sv != null and $mc != null and $sv == $mc),
       reason: (if $res.reason == null and $b.status != "approved"
                then r("policy_not_approved"; "build"; "Required policy \"Build\" is \($b.status).")
                else $res.reason end),
       evaluationId: g($b.x.evaluationId),
       expired: $exp}
  )) as $B
| ($B | map(.reason | select(. != null))) as $r_builds

# ── manual test checklist (markers and boxes only) ──
| $p.description as $d0
| (if ($d0 | type) == "string" then $d0 elif $d0 == null then "" else null end) as $d1
| (if $d1 == null then [unk("description")] else [] end) as $r_desc
| (($d1 // "") | gsub("\r\n"; "\n")) as $desc
| ($desc | split($SM)) as $sp
| (if ($sp | length) == 1 then {present: false, unreadable: false, block: ""}
   else (($sp[1:] | join($SM)) | split($EM)) as $ep
     | (if ($ep | length) == 1 then {present: true, unreadable: true, block: ""}
        else {present: true, unreadable: false, block: $ep[0]} end)
   end) as $cb
| ($cb.block | split("\n")) as $lines
| ($lines | reduce .[] as $ln ({h: "", items: [], ticked: 0};
    if ($ln | test("^\\s*####")) then .h = ($ln | sub("^\\s*#+\\s*"; "") | clean)
    elif ($ln | test("^\\s*[-*+]\\s+\\[[xX]\\]")) then .ticked += 1
    elif ($ln | test("^\\s*[-*+]\\s+\\[ \\]")) then .items += [{heading: .h, text: ($ln | sub("^\\s*[-*+]\\s+\\[ \\]\\s*"; "") | clean)}]
    else . end)) as $ck
| ($ck.items | length) as $unticked
| ($lines | map(select(test("scored at `[0-9a-fA-F]{7,40}`"))) | .[0]) as $ratingRaw
| ($lines | map(select(test("^\\s*(回復方式|Rollback)\\s*[:：]"))) | .[0]) as $rollbackRaw
| ($cb.block | [match("scored at `([0-9a-fA-F]{7,40})`").captures[0].string] | .[0]) as $sha
| (if $sha == null or $head == null then null
   else ((($head | startswith($sha | ascii_downcase))) or (($sha | ascii_downcase) | startswith($head))) end) as $cur
| (if $cb.unreadable then [r("checklist_unreadable"; null; "Risk-assessment block has a start marker without an end marker.")] else [] end) as $r_unread
| (if $unticked > 0 then [r("checklist_unticked"; null; "\($unticked) manual test item(s) unticked.")] else [] end) as $r_unt
| (if $cur == false then [r("checklist_stale"; null; "Checklist was scored at \($sha | sh8), but the PR head is \($head | sh8).")] else [] end) as $r_stale
| ($waive and ($r_unt | length) > 0) as $wu
| ($waive and ($r_stale | length) > 0) as $ws

# ── merge message: PR title + description without the risk-assessment block ──
| ($desc
    | gsub("<!-- risk-assessment:start -->[\\s\\S]*?<!-- risk-assessment:end -->"; "")
    | gsub("\n{3,}"; "\n\n")
    | gsub("\\A\\s+|\\s+\\z"; "")) as $body
| ($t + (if $body == "" then "" else "\n\n" + $body end)) as $msg
| ($msg | split("\n")) as $ml
| (if any($ml[]; test("^\\s*co-authored-by\\s*:.*(claude|anthropic|codex|openai|copilot|chatgpt|gemini|cursor|aider|devin)"; "i")) then [r("message_attribution"; "coAuthoredBy"; "Merge message contains an AI co-author trailer.")]
   elif any($ml[]; test("generated\\s+(with|by)\\b.*(claude|anthropic|codex|openai|copilot|chatgpt|gemini|cursor|aider|devin)"; "i")) then [r("message_attribution"; "generatedWith"; "Merge message contains an AI attribution line.")]
   else [] end) as $r_attr

# ── head pin supplied by --execute ──
| (if $headArg != "" and $head != null and (($head | startswith($headArg | ascii_downcase)) | not)
   then [r("head_mismatch"; null; "PR head is \($head | sh8), not the previewed \($headArg | .[0:8]).")]
   else [] end) as $r_hm

| ($r_status + $r_draft + $r_merge + $r_head + $r_mc + $r_title + $r_desc + $r_rvfmt + $r_vote + $r_rej + $r_appr
   + $r_evfmt + $r_evinv + $r_pol + $r_blfmt + $r_builds + $r_unread + $r_unt + $r_stale + $r_attr + $r_hm) as $all
| ($all | map(select(((.code == "checklist_unticked" or .code == "checklist_stale") and $waive) | not)) | dedupe) as $eff
| (if ($eff | length) == 0 then "ready" else "blocked" end) as $verdict
| {
    pub: {
      status: ($st | enum(["active", "completed", "abandoned"])),
      isDraft: (if ($p.isDraft | type) == "boolean" then $p.isDraft else null end),
      mergeStatus: ($ms | enum(["succeeded", "conflicts", "queued", "notSet", "failure", "rejectedByPolicy"])),
      head: $head,
      mergeCommit: $mc,
      verdict: $verdict,
      reasons: ($eff | map({code, subject})),
      approvals: {approved: $approved, rejected: $rejected, requiredPending: $reqPending},
      policies: ($N | map({kind, status: (if .statusKnown then .status else "unknown" end), blocking: (if (.blocking | type) == "boolean" then .blocking else null end)})),
      builds: ($B | map({definitionId, state, current})),
      checklist: {
        present: $cb.present,
        total: ($ck.ticked + $unticked),
        ticked: $ck.ticked,
        unticked: $unticked,
        unreadable: $cb.unreadable,
        scoredAtCurrent: $cur,
        untickedBlocking: (($r_unt | length) > 0 and ($waive | not)),
        staleBlocking: (($r_stale | length) > 0 and ($waive | not)),
        waivedUnticked: $wu,
        waivedStale: $ws
      }
    },
    message: $msg,
    detail: $eff,
    requeue: ($B | map(select(.expired) | .evaluationId)),
    text: (
      ["   \($t | clean)",
       "   Head: \($head | sh8)   Merge commit: \($mc | sh8)",
       "───────────────────────────────────────────────────────────"]
      + ($B | map((if .state == "succeeded" and .current then "✅" elif .state == "pending" then "⏳" elif .state == "expired" then "♻️ " else "❌" end) + " build " + .name + " (" + .state + (if .state == "succeeded" and (.current | not) then ", not on the current merge commit" else "" end) + ")"))
      + [(if $verdict == "ready" then "✅ Verdict: ready" else "❌ Verdict: blocked" end)]
      + ($eff | map("❌ \(.code): \(.message)"))
      + (if $wu then ["⚠️  Waived (--waive-checklist): \($unticked) unticked manual test item(s)."] else [] end)
      + (if $ws then ["⚠️  Waived (--waive-checklist): the checklist score is stale."] else [] end)
      + (if $waive and ($wu | not) and ($ws | not) then ["note: --waive-checklist had nothing to waive."] else [] end)
      + (if ($cb.present | not) then ["Checklist: no risk assessment"]
         elif $cb.unreadable then ["Checklist: unreadable"]
         else ["Checklist: \($ck.ticked)/\($ck.ticked + $unticked) ticked"
               + (if $unticked == 0 then " (checklist complete)" else "" end)]
              + ($ck.items | map("  ☐ [\(.heading)] \(.text)"))
              + (if $ratingRaw != null then ["  " + ($ratingRaw | clean)] else [] end)
              + (if $rollbackRaw != null then ["  " + ($rollbackRaw | clean)] else [] end)
         end)
    )
  }
EOF

# ── Data collection (GET only) ───────────────────────────────────────
PR_JSON=""
EVALS_JSON=null
BUILDS_JSON=null

fetch_pr() {
  http_json -H "$AUTH_HEADER" "$PR_URL"
}

collect() {
  local project_id artifact_encoded needs_builds
  PR_JSON=$(fetch_pr)
  EVALS_JSON=null
  BUILDS_JSON=null

  project_id=$(printf '%s' "$PR_JSON" | jq -r 'try (.repository.project.id | strings) catch empty' 2>/dev/null || true)
  if [[ "$project_id" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    artifact_encoded=$(jq -rn --arg a "vstfs:///CodeReview/CodeReviewId/${project_id}/${PR_ID}" '$a | @uri')
    EVALS_JSON=$(http_json -H "$AUTH_HEADER" \
      "${API_BASE}/_apis/policy/evaluations?artifactId=${artifact_encoded}&api-version=7.1-preview.1")
    needs_builds=$(printf '%s' "$EVALS_JSON" | jq -r 'try ([.value[] | select(.configuration.type.displayName == "Build" and .configuration.isBlocking != false and .status != "notApplicable")] | length > 0) catch false' 2>/dev/null || echo false)
    if [ "$needs_builds" = true ]; then
      BUILDS_JSON=$(http_json -H "$AUTH_HEADER" \
        "${API_BASE}/_apis/build/builds?branchName=refs/pull/${PR_ID}/merge&\$top=100&queryOrder=queueTimeDescending&api-version=7.1")
    fi
  fi
}

RESULT=""
assess() {
  local waive_json=false
  if [ "$WAIVE" = true ]; then waive_json=true; fi
  # jq diagnostics can quote API data, so a failure reports a fixed message instead.
  if ! RESULT=$(printf '{"pr":%s,"evals":%s,"builds":%s}' "$PR_JSON" "$EVALS_JSON" "$BUILDS_JSON" \
    | jq -c --argjson waive "$waive_json" --arg headArg "$HEAD_ARG" "$ASSESS_JQ" 2>/dev/null); then
    echo "❌ Could not evaluate merge readiness: unexpected API response." >&2
    exit 1
  fi
}

result_field() {
  printf '%s' "$RESULT" | jq -r "$1"
}

print_preview() {
  local head waive_flag
  if [ "$JSON" = true ]; then
    printf '%s' "$RESULT" | jq -c --argjson id "$PR_ID" --arg org "$ADO_ORG" --arg project "$PROJECT" --arg repo "$REPO_NAME" \
      '{pullRequestId: $id, organization: $org, project: $project, repository: $repo} + .pub'
    return
  fi
  echo ""
  echo "🔀 PR #${PR_ID}  (${PROJECT}/${REPO_NAME})"
  result_field '.text[]'
  if [ "$(result_field '.pub.verdict')" = ready ]; then
    head=$(result_field '.pub.head')
    echo ""
    echo "Preview only; nothing was changed. After the owner approves this head, merge with:"
    waive_flag=""
    if [ "$WAIVE" = true ]; then waive_flag=" --waive-checklist"; fi
    echo "  pr merge ${PR_ID} --execute --head ${head}${waive_flag}"
  fi
  echo ""
}

# JSON result of --execute; arguments: result, merge commit (may be empty), reasons JSON.
VERIFIED_HEAD=""
WAIVED=false
print_execute_json() {
  jq -nc --argjson id "$PR_ID" --arg org "$ADO_ORG" --arg project "$PROJECT" --arg repo "$REPO_NAME" \
    --arg result "$1" --arg mergeCommit "${2:-}" --argjson reasons "${3:-[]}" \
    --arg head "$VERIFIED_HEAD" --argjson waived "$WAIVED" '
      {pullRequestId: $id, organization: $org, project: $project, repository: $repo,
       result: $result, reasons: $reasons,
       head: (if $head == "" then null else $head end),
       mergeCommit: (if $mergeCommit == "" then null else $mergeCommit end),
       waivedChecklist: $waived}'
}

# Report a non-merge outcome of --execute and exit 1. Arguments: result, text line, reasons JSON.
execute_stop() {
  local result="$1" line="$2" reasons="${3:-[]}"
  if [ "$JSON" = true ]; then
    print_execute_json "$result" "" "$reasons"
  else
    echo ""
    echo "🔀 PR #${PR_ID}  (${PROJECT}/${REPO_NAME})"
    echo "$line"
    echo ""
  fi
  exit 1
}

# ── --requeue-expired ────────────────────────────────────────────────
if [ "$REQUEUE" = true ]; then
  collect
  if ! printf '%s' "$PR_JSON" | jq -e '.status == "active"' >/dev/null 2>&1; then
    echo "❌ PR #${PR_ID} is not active; nothing was requeued." >&2
    exit 1
  fi
  assess
  REQUEUED=0
  for EVALUATION_ID in $(result_field '.requeue[] | select(type == "string")'); do
    if [[ ! "$EVALUATION_ID" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
      echo "❌ Unexpected evaluation id in the policy response; stopping." >&2
      exit 1
    fi
    if ! http_json -X PATCH -H "$AUTH_HEADER" -H "Content-Type: application/json" \
      "${API_BASE}/_apis/policy/evaluations/${EVALUATION_ID}?api-version=7.1-preview.1" -d '{}' >/dev/null; then
      echo "❌ Requeue failed after ${REQUEUED} evaluation(s)." >&2
      exit 1
    fi
    REQUEUED=$((REQUEUED + 1))
  done
  if [ "$REQUEUED" -eq 0 ]; then
    echo "No expired build evaluations to requeue."
  else
    echo "♻️  Requeued ${REQUEUED} expired build evaluation(s). Wait for the new builds, then re-run the preview."
  fi
  collect
  assess
  print_preview
  exit 0
fi

# ── Preview ──────────────────────────────────────────────────────────
collect
assess

if [ "$EXECUTE" != true ]; then
  print_preview
  exit 0
fi

# ── --execute ────────────────────────────────────────────────────────
VERIFIED_HEAD=$(result_field '.pub.head // empty')
if [ "$(result_field '[.pub.checklist.waivedUnticked, .pub.checklist.waivedStale] | any')" = true ]; then
  WAIVED=true
fi

if [ "$(result_field '.pub.verdict')" != ready ]; then
  REASONS=$(result_field '.pub.reasons' | jq -c .)
  if [ "$JSON" = true ]; then
    print_execute_json refused "" "$REASONS"
  else
    echo ""
    echo "🔀 PR #${PR_ID}  (${PROJECT}/${REPO_NAME})"
    echo "❌ Refusing to merge; nothing was sent."
    result_field '.detail[] | "❌ \(.code): \(.message)"'
    echo ""
  fi
  exit 1
fi

# The head is verified against fresh data, so re-read the PR right before the write. Anything
# that moved since the verification (source head, merge commit, status) cancels the merge.
PR_RECHECK=$(fetch_pr)
if ! printf '[%s,%s]' "$PR_JSON" "$PR_RECHECK" | jq -e '
  map({s: .status, h: .lastMergeSourceCommit.commitId, m: .lastMergeCommit.commitId}) | .[0] == .[1]' >/dev/null 2>&1; then
  execute_stop refused "❌ head_mismatch: the PR changed (head, merge commit or status) after it was verified. Nothing was sent; re-run the preview." \
    '[{"code":"head_mismatch","subject":"reread"}]'
fi

MESSAGE=$(result_field '.message')
MERGE_BODY=$(printf '%s' "$MESSAGE" | jq -Rsc --arg head "$VERIFIED_HEAD" '
  {status: "completed",
   lastMergeSourceCommit: {commitId: $head},
   completionOptions: {mergeStrategy: "squash", deleteSourceBranch: true,
                       transitionWorkItems: true, mergeCommitMessage: .}}')
# Policy is never bypassed: the body is an allowlist and must carry no bypass key.
if ! printf '%s' "$MERGE_BODY" | jq -e --arg head "$VERIFIED_HEAD" '
  ([.. | objects | has("bypassPolicy")] | any | not)
  and .completionOptions.mergeStrategy == "squash"
  and .lastMergeSourceCommit.commitId == $head' >/dev/null; then
  echo "❌ Internal error: the merge request body failed its safety check; nothing was sent." >&2
  exit 1
fi

if ! PATCH_OUT=$(http_json -X PATCH -H "$AUTH_HEADER" -H "Content-Type: application/json" "$PR_URL" -d "$MERGE_BODY" 2>&1); then
  case "$PATCH_OUT" in
    *"HTTP 400"*) HINT="The merge message may be too long (about 4000 characters); shorten the PR description and retry." ;;
    *"HTTP 403"*) HINT="A blocking policy is not satisfied; a build policy may have expired after the target moved. Re-run the preview." ;;
    *) HINT="The request did not return a result, so the merge may or may not have been applied. Check the PR before retrying." ;;
  esac
  execute_stop failed "${PATCH_OUT} ${HINT}"
fi

# Completion can be queued: poll until the PR reports completed.
DEADLINE=$((SECONDS + TIMEOUT))
while :; do
  if ! POLL_JSON=$(fetch_pr 2>&1); then
    execute_stop failed "❌ Could not read the PR after the merge request, so the outcome is unknown. Check the PR before retrying."
  fi
  POLL_STATUS=$(printf '%s' "$POLL_JSON" | jq -r '.status // empty' 2>/dev/null || true)
  case "$POLL_STATUS" in
    completed)
      MERGE_COMMIT=$(printf '%s' "$POLL_JSON" | jq -r 'try (.lastMergeCommit.commitId | select(test("^[0-9a-fA-F]{40}$"))) catch empty' 2>/dev/null || true)
      if [ "$JSON" = true ]; then
        print_execute_json completed "$MERGE_COMMIT" '[]'
      else
        echo ""
        echo "🔀 PR #${PR_ID}  (${PROJECT}/${REPO_NAME})"
        echo "✅ Completed (squash). Merge commit: ${MERGE_COMMIT:-not reported}"
        echo "   Source branch deletion was requested."
        echo ""
      fi
      exit 0
      ;;
    abandoned)
      execute_stop abandoned "❌ The PR is now abandoned; it was not merged."
      ;;
  esac
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    execute_stop timeout "⏳ The merge request was accepted, but the PR is not completed after ${TIMEOUT}s. It is not confirmed as merged; check the PR before retrying."
  fi
  sleep "$INTERVAL"
done
