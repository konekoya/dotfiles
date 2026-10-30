# Azure DevOps PR Operations

Read this reference only for Azure DevOps remotes. Use `ado-rest` for Azure DevOps API calls. Optional ClickUp requests use `curl` and `jq`.

## Authentication and repository context

Verify the selected repository profile before any Azure DevOps API operation:

```bash
ADO_CONTEXT=$(ado-rest context)
ORG=$(printf '%s' "$ADO_CONTEXT" | jq -r '.organization')
PROJECT=$(printf '%s' "$ADO_CONTEXT" | jq -r '.project')
REPO=$(printf '%s' "$ADO_CONTEXT" | jq -r '.repository')
REMOTE=$(printf '%s' "$ADO_CONTEXT" | jq -r '.remote')
BRANCH=$(git branch --show-current)
```

If `ado-rest context` fails, stop and report its non-sensitive setup guidance. It validates the selected remote's fetch/push pair and binds the repository organization to its configured profile. Do not print raw remote URLs or switch Azure CLI accounts/subscriptions.

## Existing PR and default branch

Check whether an open PR already exists for this branch. Filter the active PR list by exact source ref so branch names containing `#` are handled safely:

```bash
BRANCH=$(git branch --show-current)
RESULT=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests?searchCriteria.status=active&api-version=7.1")
MATCHES=$(printf '%s' "$RESULT" | jq -c --arg branch "refs/heads/${BRANCH}" '[.value[]? | select(.sourceRefName == $branch)]')
```

- If one PR is found, store its **PR ID**, current **title**, current **description**, and current **target branch** (`targetRefName`, stripped of `refs/heads/`) — the skill will update that PR instead of creating a new one. If several match, ask which one to update.
- If no PR exists, continue normally to create a new one.

Check the API response before inspecting matches; an API/authentication failure is not evidence that no PR exists. Preserve `isDraft` and reviewer defaults from an existing PR. If the remote default branch is unavailable locally:

```bash
ado-rest GET "/_apis/git/repositories/${REPO}?api-version=7.1" | jq -r '.defaultBranch // empty'
```

Strip `refs/heads/` from the result.

## Draft title and description

Extract the ClickUp task ID from the current branch name:

```bash
git branch --show-current
```

Branch naming convention: `feat/#<taskId>` (e.g. `feat/#86abc123` → task ID is `86abc123`).
If the branch matches this pattern, pre-fill the ClickUp URL as `https://app.clickup.com/t/<taskId>`.

The ClickUp token is not exported by the interactive shell; it lives in `alias/.env` and every ClickUp snippet below loads it with `source "$(command -v local-env)" CLICKUP_API_TOKEN`, which sets a plain non-exported variable and prints nothing (an already-exported value wins). Never `export` or echo the variable. Treat the token as unset when it is still empty after that line.

If a ClickUp task ID was found and `CLICKUP_API_TOKEN` is set, fetch the task's title — `create-clickup-task` drafts ClickUp task titles as plain natural-language sentences with no Conventional Commit prefix, so build the PR title by adapting that title rather than re-drafting one from the diff:

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
curl -s -H "Authorization: ${CLICKUP_API_TOKEN}" "https://api.clickup.com/api/v2/task/<taskId>" | jq -r '.name'
```

If `CLICKUP_API_TOKEN` isn't set, or the fetch fails, fall back to drafting `<description>` from the diff/commits as usual — this integration is optional, same as everywhere else ClickUp shows up in this repo.

**Title.** Format: `[#<taskId>] <description>` if a ClickUp task ID/URL is available, otherwise `<type>: <description>`. The Conventional Commit type prefix is only used when there's no ClickUp task ID to anchor the PR — once a task ID is available, the `[#<taskId>]` bracket alone identifies the change and the `type:`/`type(scope):` prefix is dropped.

- `<type>` is the Conventional Commit type resolved in shared step 5 — only relevant when there's no ClickUp task ID.
- `<description>`:
  - If a ClickUp task ID/URL is available and a ClickUp task title was fetched above: use it as the description as-is, capitalization included — don't redraft it from the diff or lowercase it, the ClickUp title is already the source of truth for what this PR does.
  - If a ClickUp task ID/URL is available but no title could be fetched (token unset or fetch failed): draft it from the diff/commits gathered in shared step 4, lowercase, imperative mood, no trailing period — same as the no-ClickUp case below — but still omit the `<type>:` prefix, since the bracket is present.
  - Otherwise (no ClickUp task ID at all): draft it from the diff/commits gathered in shared step 4, lowercase, imperative mood ("add", "fix", "remove" — not "Added", "Fixes"), no trailing period. If the change is scoped to a clear area, optionally use `type(scope): subject`.
- Example with ClickUp ID: `[#z91464g58x] Update editor file menu behavior`.
- Example without: `fix: upload overlay ignoring entity z-order`.

**If a title is already available** — supplied as the skill argument, or an existing PR title being reused in update mode — use it as-is, but still verify it matches the format above and correct it if not:

- Add the ClickUp bracket if one is available and missing.
- If a ClickUp bracket is present (or was just added): strip any `<type>:` or `<type>(<scope>):` prefix that follows it — it doesn't belong once the bracket anchors the PR to a task.
- If no ClickUp bracket is available: insert the type prefix resolved in shared step 5 if missing, or correct it if present but not one of the table in shared step 5.
- Don't touch parts of the title that are already correct.

**Description.** Follow the exact structure the `summarize-pr` skill uses: default to Traditional Chinese (繁體中文) unless the user or repository instructions require another language. Section headings (`## 摘要`, `## 主要變更`, `## 測試`, `## Code Review`) and prose are in Chinese; code identifiers, file paths, function/variable names, and error strings stay verbatim in their original form.

- **`## 摘要`** (1–2 sentences) — core purpose and impact; the reader should understand the goal in one read.
- **`## 主要變更`** (grouped bullets) — grouped logically by domain/layer (feature/fix/refactor/tests/docs as applicable), from the implementation's perspective, not a verbatim replay of commit messages. Subheadings OK if groups are substantial. Keep bullets short and scannable; testing-related bullets belong only in `## 測試`, never repeated here.
- **`## 測試`** (bullet or paragraph) — test files added or modified (UT/IT/E2E), one bullet each with what it covers. If no tests added, note that. Don't include run status, pass counts, or manual test steps — every PR is already gated by CI.
- **`## Code Review`** (bullet or paragraph) — review rounds and key feedback addressed, conflicts resolved, pull from PR comment threads if available (cross-reference `pr-comments`/`address-pr-review`), not just local git. Only include this section if the branch has actually been through review — for a brand-new PR being created here, that will almost always mean omitting it entirely, so don't emit an empty heading. (In update mode, check whether the existing PR has review history before deciding.)

The `Closes <ClickUp URL>` line still goes at the very top, above the risk block and `## 摘要`, separated by a blank line. The marked `## 風險評估` block from [risk-assessment.md](risk-assessment.md) sits between them:

```markdown
Closes <ClickUp URL>

<!-- risk-assessment:start -->
## 風險評估
<overall level, per-dimension findings, and the checks a human should do>
<!-- risk-assessment:end -->

## 摘要
<1–2 sentence summary>

## 主要變更
- <change 1>
- <change 2>

## 測試
- <test coverage, or note that none was added>
```

If no ClickUp URL was provided, omit the `Closes` line entirely (do not leave a blank line at the top).

## Publish

Read the approved body file as one string:

```bash
PR_DESCRIPTION=$(cat "$PR_BODY_FILE")
```

Create:

```bash
PR_CREATE_BODY=$(jq -n \
  --arg source "refs/heads/${BRANCH}" \
  --arg target "refs/heads/${TARGET_BRANCH}" \
  --arg title "$PR_TITLE" \
  --arg description "$PR_DESCRIPTION" \
  --argjson isDraft "$IS_DRAFT" \
  '{sourceRefName: $source, targetRefName: $target, title: $title, description: $description, isDraft: $isDraft}')
PR_RESULT=$(ado-rest POST "/_apis/git/repositories/${REPO}/pullrequests?api-version=7.1" "$PR_CREATE_BODY")
PR_ID=$(printf '%s' "$PR_RESULT" | jq -r '.pullRequestId')
```

Set `IS_DRAFT` to `true` for a requested draft and `false` otherwise. When reviewers are requested, resolve each identity to its Azure DevOps identity ID, then include a `reviewers` array of `{id: "<identity-id>"}` entries in the create body. Preserve reviewer defaults for existing PRs.

Update:

```bash
PR_UPDATE_BODY=$(jq -n --arg title "$PR_TITLE" --arg description "$PR_DESCRIPTION" \
  '{title: $title, description: $description}')
if [ "$DRAFT_STATE_REQUESTED" = true ]; then
  PR_UPDATE_BODY=$(printf '%s' "$PR_UPDATE_BODY" | jq --argjson isDraft "$IS_DRAFT" '. + {isDraft: $isDraft}')
fi
ado-rest PATCH "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}?api-version=7.1" "$PR_UPDATE_BODY"
```

Include `isDraft` only when the user requested a draft-state change. Add requested reviewers using their resolved identity IDs with the PR reviewers API; preserve existing reviewers unless removal is explicitly requested.

For an explicitly requested retarget, use the [Azure DevOps PR update API](https://learn.microsoft.com/en-us/rest/api/azure/devops/git/pull-requests/update?view=azure-devops-rest-7.1) through `ado-rest`:

```bash
PR_TARGET_BODY=$(jq -n --arg target "refs/heads/${TARGET_BRANCH}" '{targetRefName: $target}')
ado-rest PATCH "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}?api-version=7.1" "$PR_TARGET_BODY"
```

Retargeting requires the service's PR retargeting feature. If unsupported or rejected, stop and report the failure; do not create a replacement PR. Verify final metadata with `ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}?api-version=7.1"`.

## Add the PR backlink to ClickUp (best-effort)

Run this only after the Publish section confirms the PR was created or updated successfully. This is a best-effort backlink: a missing ClickUp URL/token, a declined preview, or any ClickUp API failure must not undo, delete, or retry the successful PR operation.

Use the PR ID returned by `ado-rest` in create mode or the existing PR ID from shared step 2 in update mode. Build `PR_URL` using the same canonical user-facing URL shown in shared step 7. Resolve it before checking ClickUp availability so the PR result can still be reported when the backlink is skipped:

```bash
PR_URL="https://dev.azure.com/<org>/<project-url-encoded>/_git/<repo>/pullrequest/${PR_ID}"
```

Set `CLICKUP_URL` to the URL collected in shared step 5, including a URL prefilled from the branch in the Draft section. If that field is blank, use a single ClickUp task URL already present in the final PR description if one can be identified unambiguously. Before calling ClickUp, check both prerequisites: if no usable task URL is available, report `skipped: no usable ClickUp task URL`; if `CLICKUP_API_TOKEN` is unset (check with `source "$(command -v local-env)" CLICKUP_API_TOKEN; [ -n "${CLICKUP_API_TOKEN:-}" ]`), report `skipped: CLICKUP_API_TOKEN is unset`. Report both reasons when both apply. If either prerequisite is missing, do not run the ClickUp ID lookup or API requests; continue directly to shared step 7.

Extract the ClickUp task ID from the final path segment of its URL after removing any trailing slash, query, or fragment. For a URL such as `https://app.clickup.com/t/<workspace_id>/<task_id>`, use `<task_id>`:

```bash
CLICKUP_TASK_ID=$(printf '%s' "$CLICKUP_URL" | sed -E 's/[?#].*$//; s#/*$##; s#.*/##')
```

If no usable task ID can be extracted, skip the backlink, report `skipped: no usable ClickUp task URL`, and continue to shared step 7.

Fetch and validate the task before preparing an update. Request its Markdown description to preserve the headings and lists. Treat a failed request, non-200 response, invalid JSON, missing/mismatched task ID, or missing/non-string `markdown_description` as a backlink failure; report it and leave the PR as-is. If this fetch fails, skip the rest of the backlink step and the Code Review status offer below, and continue to shared step 7:

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
TASK_FETCH_RESULT=$(curl -sS -w "\n%{http_code}" \
  -H "Authorization: ${CLICKUP_API_TOKEN}" \
  "https://api.clickup.com/api/v2/task/${CLICKUP_TASK_ID}?include_markdown_description=true")

TASK_FETCH_HTTP=$(printf '%s\n' "$TASK_FETCH_RESULT" | tail -n 1)
TASK_JSON=$(printf '%s\n' "$TASK_FETCH_RESULT" | sed '$d')
FETCHED_TASK_ID=$(printf '%s' "$TASK_JSON" | jq -r '.id // empty' 2>/dev/null)

if [ "$TASK_FETCH_HTTP" != "200" ] || [ "$FETCHED_TASK_ID" != "$CLICKUP_TASK_ID" ] \
  || ! CURRENT_TASK_DESC=$(printf '%s' "$TASK_JSON" | jq -er '.markdown_description | select(type == "string")'); then
  echo "⚠️ ClickUp backlink failed: could not fetch task ${CLICKUP_TASK_ID} (HTTP ${TASK_FETCH_HTTP}). The PR remains created/updated."
else
  TASK_LIST_ID=$(printf '%s' "$TASK_JSON" | jq -r '.list.id // empty')
  TASK_CURRENT_STATUS=$(printf '%s' "$TASK_JSON" | jq -r '.status.status // empty')
fi
```

Use the fetched `markdown_description` and update with `markdown_content`, as in `create-clickup-task` step 11. Do not fall back to the plain-text `description`, which would strip existing headings and lists. If the canonical `PR_URL` is already present in `CURRENT_TASK_DESC`, do not update the task and report `already present`. Otherwise prepend one labeled link to the top of the Markdown description, preserving the existing content:

```bash
if [[ "$CURRENT_TASK_DESC" == *"$PR_URL"* ]]; then
  NEW_TASK_DESC="$CURRENT_TASK_DESC"
else
  if [ -n "$CURRENT_TASK_DESC" ]; then
    NEW_TASK_DESC=$(printf 'PR #%s: %s\n\n%s' "$PR_ID" "$PR_URL" "$CURRENT_TASK_DESC")
  else
    NEW_TASK_DESC=$(printf 'PR #%s: %s' "$PR_ID" "$PR_URL")
  fi
fi
```

When the URL is absent, preview the complete before-and-after task descriptions, then use `ask_user` for **Add backlink** / **Skip**. Never call the update endpoint without explicit approval. If approved, send only the additive description update:

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
TASK_UPDATE_BODY=$(jq -n --arg md "$NEW_TASK_DESC" '{markdown_content: $md}')
TASK_UPDATE_RESULT=$(curl -sS -w "\n%{http_code}" \
  -X PUT \
  -H "Authorization: ${CLICKUP_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.clickup.com/api/v2/task/${CLICKUP_TASK_ID}" \
  -d "$TASK_UPDATE_BODY")

TASK_UPDATE_HTTP=$(printf '%s\n' "$TASK_UPDATE_RESULT" | tail -n 1)
```

Report `added` only for a successful update response; otherwise report `failed` with the HTTP status or API error. A user who skips the preview should be reported as `skipped: user declined`. Do not retry or roll back the PR because this ClickUp update failed.

#### Offer to set Code Review status (best-effort)

Only attempt this when the task fetch above succeeded (`TASK_LIST_ID` and `TASK_CURRENT_STATUS` are set) — if it failed, this was already skipped and there's nothing to offer. This is independent of the backlink outcome: offer the status change regardless of whether the backlink was added, already present, skipped, or failed.

If `TASK_CURRENT_STATUS` (case-insensitive) is already `"code review"`, report `already "Code Review"` and continue to shared step 7 — nothing to change.

Otherwise, resolve the task's list statuses and look for one matching "code review":

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
LIST_STATUSES_JSON=$(curl -sS -H "Authorization: ${CLICKUP_API_TOKEN}" \
  "https://api.clickup.com/api/v2/list/${TASK_LIST_ID}" \
  | jq -r '.statuses // []' 2>/dev/null)

CR_MATCHES=$(echo "$LIST_STATUSES_JSON" | jq -r '[.[] | select(.status | ascii_downcase == "code review")]' 2>/dev/null)
if [ "$(echo "$CR_MATCHES" | jq 'length' 2>/dev/null)" = "0" ]; then
  CR_MATCHES=$(echo "$LIST_STATUSES_JSON" | jq -r '[.[] | select(.status | ascii_downcase | contains("review"))]' 2>/dev/null)
fi
CR_MATCH_COUNT=$(echo "$CR_MATCHES" | jq 'length' 2>/dev/null || echo 0)
```

If the `GET /list/${TASK_LIST_ID}` call fails or returns no statuses, report `failed: could not fetch list statuses` and continue to shared step 7 — never retry or touch the PR over this.

- If `CR_MATCH_COUNT` is `1`: use `ask_user` with that status pre-selected as the default (**Set to `<matched name>`** / **Choose a different status** / **Skip**).
- If `CR_MATCH_COUNT` is `0` or more than `1`: fall back to a manual `ask_user` picker over the full status list (`.status` names from `LIST_STATUSES_JSON`), plus **Skip**.

If the user picks a status, apply it:

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
STATUS_UPDATE_RESULT=$(curl -sS -w "\n%{http_code}" \
  -X PUT \
  -H "Authorization: ${CLICKUP_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.clickup.com/api/v2/task/${CLICKUP_TASK_ID}" \
  -d "$(jq -n --arg status "$CHOSEN_STATUS" '{status: $status}')")

STATUS_UPDATE_HTTP=$(printf '%s\n' "$STATUS_UPDATE_RESULT" | tail -n 1)
```

Report `updated to "<CHOSEN_STATUS>"` on a `200` response; otherwise `failed` with the HTTP status. A user who declines the prompt is `skipped: user declined`. Never retry or roll back the PR because this status update failed — same rule as the backlink.

## Result

Report created/updated, PR ID/title, source → target, `PR_URL`, the overall risk level, plus ClickUp backlink and status outcomes: added/updated, already present, skipped (with reason), or failed (with reason).
