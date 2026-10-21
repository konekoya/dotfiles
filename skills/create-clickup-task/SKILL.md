---
name: create-clickup-task
description: 'Create a new ClickUp task, either from a direct instruction or by summarizing the current branch/PR when no ticket exists yet for already-completed work. Asks whether it goes into a list or as a subtask of an existing task, and lets you pick its real ClickUp task type (Task, Bug, or whatever custom types the workspace has); assigns it to you by default. In from-PR mode, offers bidirectional linking between the ClickUp task and Azure DevOps PR. Use when: create a clickup task, create a ticket, file a task, create a subtask, no ticket yet for this PR/branch, make a clickup issue, 建立 ClickUp 任務.'
---

# Create ClickUp Task

## When to Use

When there's no ClickUp task yet and one needs to be created — either because the user is directly describing a new piece of work, or because work is already done (a branch or PR exists) but nobody filed a ticket for it beforehand. This is the inverse of the Azure DevOps mode of `create-pr`/`submit-pr`: those *consume* an existing ClickUp task ID/URL, this one *creates* the task those skills then link to.

## Prerequisites

- **ClickUp API token**: `CLICKUP_API_TOKEN` (generate at ClickUp → Settings → Apps). Same variable `submit-pr` uses. The interactive shell no longer exports it: it lives in `alias/.env` and each snippet below loads it with `source "$(command -v local-env)" CLICKUP_API_TOKEN`. That line sets a plain, non-exported variable in the snippet's own shell and prints nothing, so programs the snippet starts do not inherit it. Every Bash tool call is a fresh shell, so each snippet that uses the token starts with that line; keep it when adapting a snippet, and never `export` the variable, echo it, or enable `set -x` around these commands. A value already exported in the environment takes precedence. Residual exposure: `curl -H "Authorization: ..."` puts the token in that process's argument list while it runs.
- For from-PR mode: a git repo with an Azure DevOps remote and a matching repository profile via `ado-rest` if you also want to link the task back into a PR.

## Procedure

### 1. Verify ClickUp auth and resolve your identity

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
[ -n "${CLICKUP_API_TOKEN:-}" ] && echo "set" || echo "missing"
```

If `missing`, **stop immediately** and tell the user to generate a token at ClickUp → Settings → Apps and add `export CLICKUP_API_TOKEN=...` to `alias/.env` (or export it in the environment).

Fetch the token owner's identity once — used later to default the new task's assignee to "you":

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
ME_RESPONSE=$(curl -s -H "Authorization: ${CLICKUP_API_TOKEN}" "https://api.clickup.com/api/v2/user")
MY_USER_ID=$(echo "$ME_RESPONSE" | jq -r '.user.id')
MY_USERNAME=$(echo "$ME_RESPONSE" | jq -r '.user.username')
```

### 2. Determine mode

- **Direct-instruction mode**: the user already described what the task is about (a feature, bug, idea) — use that description as-is.
- **From-PR mode**: the user is asking to file a ticket for work that's already done ("no ticket for this branch yet", "create a ticket for this PR", "file this as a task") — derive the task from the current branch's commits/diff instead of asking the user to redescribe it.
- If it's not clear which applies, ask via `ask_user` before proceeding.

### 3. Gather context (from-PR mode only)

Validate the selected Azure DevOps remote and profile, then read the safe context fields:

```bash
ADO_CONTEXT=$(ado-rest context)
ORG=$(printf '%s' "$ADO_CONTEXT" | jq -r '.organization')
PROJECT=$(printf '%s' "$ADO_CONTEXT" | jq -r '.project')
REPO=$(printf '%s' "$ADO_CONTEXT" | jq -r '.repository')
BRANCH=$(git --no-pager branch --show-current)
```

Look for an existing PR on this branch by listing active PRs and filtering the exact source ref. This safely handles branch names containing `#`:

```bash
RESULT=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests?searchCriteria.status=active&api-version=7.1")
MATCHES=$(printf '%s' "$RESULT" | jq -c --arg branch "refs/heads/${BRANCH}" '[.value[]? | select(.sourceRefName == $branch)]')
```

An empty result just means no PR exists yet — task creation still proceeds; follow step 10's deferred-link instruction. If a PR was found, note its **PR ID** and **target branch** (`targetRefName`, stripped of `refs/heads/`) for later.

Determine the base branch (PR's target if found, otherwise the repo's default branch from `ado-rest GET "/_apis/git/repositories/${REPO}?api-version=7.1" | jq -r '.defaultBranch'`, otherwise ask), then gather the diff:

```bash
git --no-pager log <base>..HEAD --oneline
git --no-pager diff <base>...HEAD --stat
git --no-pager diff <base>...HEAD
```

Read the actual diff for non-trivial changes — don't trust commit messages alone.

### 4. Draft the title

Plain **natural English**, like any normal task title — capitalized, no Conventional Commit prefix. When the Azure DevOps mode of `create-pr` later builds the PR title from this task, it adds the `[#<taskId>]` bracket and preserves the task title without a Conventional Commit prefix.

- In from-PR mode, describe what was actually built/fixed, from the commits/diff gathered in step 3.
- In direct-instruction mode, describe what the user asked for.
- Example: `Remove website content zoom control` (not `fix: remove website content zoom control`).

### 5. Draft the description

Always **plain, easy-to-understand Traditional Chinese (繁體中文)** — a ClickUp ticket gets read by PM/QA/stakeholders as well as engineers, unlike a PR description which is purely for other engineers doing code review. Write from a product/user perspective — what changed and why it matters — not an implementation report.

- Avoid code identifiers, file names, function names, and other implementation-level jargon; that level of detail belongs in the PR description (`summarize-pr`'s job), not here.
- Use everyday wording a non-technical teammate could read and understand immediately, not engineering shorthand.
- Example — too technical (avoid): `從 WebsiteEntity 型別移除 zoom 欄位（campaign.model.ts）`. Plain (target): `移除了廣告編輯器中網站元件的縮放功能，使用者無法再調整內嵌網站的顯示比例`.

- **From-PR mode**: use `## 摘要` (1–2 plain sentences on what changed and why) and `## 主要變更` (grouped bullets in plain terms, not a code-level changelog). Add the optional `## 驗證步驟` section described below when applicable. Do not copy `summarize-pr`'s completed-test report or `## Code Review` history into the ticket.
- **Direct-instruction mode**: a short freeform 繁體中文 paragraph or bullet list, still plain and jargon-free — unless it's a bug report, see below.

Use actual Markdown lists: put each change on its own line starting with `- `, and use `1.`, `2.`, etc. for ordered procedures. Leave a blank line after each heading and before each list so ClickUp renders the items as lists rather than separate paragraphs.

**Reviewer verification (optional, either mode)**: use `## 驗證步驟` to explain how a reviewer can check whether the task meets its requirements. Write a short numbered procedure in plain Traditional Chinese, including any known setup or navigation, the action to perform, and the observable expected result for each check. Cover the changed success and failure behavior when both apply and the context explains how to exercise them. Derive the steps from the user's requirements, the diff, and known behavior or existing instructions; do not invent routes, test data, or ways to trigger failures.

Omit the entire verification section when there is no useful, repeatable reviewer check, when the available context is insufficient to write one, or when the bug's reproduction steps and expected results already provide the same check. Do not add an empty heading, a "not applicable" placeholder, or a completed-test claim such as "已完成自動化介面測試與瀏覽器實際操作驗證". Test execution history belongs in the PR; the task should tell reviewers what to do and what they should see.

**From-PR task structure** (omit the last section when it does not apply):

```markdown
## 摘要

<One or two plain Traditional Chinese sentences explaining the change and its purpose>

## 主要變更

- <First user-facing change in Traditional Chinese>
- <Second user-facing change in Traditional Chinese>

## 驗證步驟

1. <Known setup and navigation in Traditional Chinese>
2. <Action to perform and the expected visible result in Traditional Chinese>
3. <Another relevant check and its expected result, if applicable>
```

**Bug template**: when the task type (resolved in step 7) will be **Bug**, use a fixed section structure instead of a freeform paragraph, regardless of mode. Two forms exist — pick based on whether the report describes one problem or several:

**Single-issue form** (the default — one distinct symptom):

```
## 問題描述

<一兩句話說明哪裡有問題>

## 重現步驟

1. <步驟一>
2. <步驟二>
3. <步驟三>

## 目前結果

<實際發生的狀況>

## 預期結果

<應該發生的狀況>

## 影響範圍

<受影響的頁面／功能／使用者範圍>
```

**Multi-issue form** (use when the user's own bug description already lists 2+ distinct symptoms/interactions — e.g. "icon 不會保持 active、點外面 popover 不會關、網址欄位沒有自動 focus" describes three separate bugs bundled into one ticket): turn 問題描述／目前結果／預期結果 into numbered lists, one item per sub-issue, in the **same order** across all three sections, so item N always refers to the same sub-issue everywhere. 重現步驟 still reads as a natural step-by-step flow — group steps per sub-issue, or interleave them when they share setup (e.g. all three happen after opening the same toolbar), whichever reads more naturally; there's no requirement to split it 1:1 with the other sections.

```
## 問題描述

1. <問題一，一句話>
2. <問題二，一句話>
3. <問題三，一句話>

## 重現步驟

1. <共用的前置步驟，或問題一的步驟>
2. <問題二的步驟，如果不同>
3. <問題三的步驟，如果不同>

## 目前結果

1. <問題一實際發生的狀況>
2. <問題二實際發生的狀況>
3. <問題三實際發生的狀況>

## 預期結果

1. <問題一應該發生的狀況>
2. <問題二應該發生的狀況>
3. <問題三應該發生的狀況>

## 影響範圍

<受影響的頁面／功能／使用者範圍 — 可以是涵蓋所有子問題的一段共用描述>
```

Default to the single-issue form. Switch to the multi-issue form only when the user's own wording already signals multiple *distinct symptoms* — not just multiple repro steps toward one symptom; a single bug with a 5-step reproduction is still single-issue.

Since task type isn't resolved until step 7, draft with whichever form applies directly whenever the user's own wording already signals a defect report (e.g. "bug", "壞掉", "問題", "不會消失", "沒反應"); otherwise draft normally in step 5 and redraft using the appropriate form if step 7 ends up resolving to "Bug".

### 6. Resolve the target — a list, or a parent task for a subtask

ClickUp's create-task endpoint always needs a list ID in the URL — even a subtask lives in a list (the same list its parent is in). Ask via `ask_user` which applies:

- **Into a list** (the common case) — a plain top-level task.
- **As a subtask of an existing task** — nested under a task that already exists.

**Into a list**: maintain a small per-machine pick-list at `~/.clickup_lists.json` (plays the same role `.user_alias` plays for aliases — local, reusable, not part of the repo):

```bash
LISTS_FILE="$HOME/.clickup_lists.json"
[ -f "$LISTS_FILE" ] || echo '[]' > "$LISTS_FILE"
jq -r '.[] | "\(.id): \(.name)"' "$LISTS_FILE"
```

Present the saved lists (by name) via `ask_user`, with an extra "Add a new list" option.

If adding a new list (or the file is empty): ask for a ClickUp List ID or List URL, then extract the numeric ID — handles both a bare ID and a URL like `https://app.clickup.com/<team>/v/li/<id>`:

```bash
LIST_ID=$(echo "$INPUT" | grep -oE '[0-9]+$')
```

Validate it and fetch the real name so the user never has to type one:

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
LIST_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: ${CLICKUP_API_TOKEN}" \
  "https://api.clickup.com/api/v2/list/${LIST_ID}")

LIST_HTTP=$(echo "$LIST_RESPONSE" | tail -1)
LIST_BODY=$(echo "$LIST_RESPONSE" | sed '$d')

if [ "$LIST_HTTP" != "200" ]; then
  echo "⚠️  Could not fetch list ${LIST_ID} (HTTP ${LIST_HTTP}). Check the ID/URL and your ClickUp access."
else
  LIST_NAME=$(echo "$LIST_BODY" | jq -r '.name')
fi
```

If validation failed, ask again rather than saving an unvalidated entry. Otherwise append it (deduping by id):

```bash
jq --arg id "$LIST_ID" --arg name "$LIST_NAME" \
  'map(select(.id != $id)) + [{id: $id, name: $name}]' \
  "$LISTS_FILE" > "$LISTS_FILE.tmp" && mv "$LISTS_FILE.tmp" "$LISTS_FILE"
```

**As a subtask**: ask for the parent task's ID or URL. Task URLs can be the short form (`https://app.clickup.com/t/<task_id>`) or a form with a workspace id in front of it (`https://app.clickup.com/t/<workspace_id>/<task_id>`) — either way the task ID is just the last path segment, so a plain "strip everything up to the last slash" handles both, and leaves a bare ID untouched:

```bash
PARENT_TASK_ID=$(echo "$INPUT" | sed -E 's#.*/##')
```

Fetch it — same `GET /task/{id}` call `submit-pr` already uses — to validate it and derive the list it lives in (a subtask must be created into its parent's own list):

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
PARENT_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: ${CLICKUP_API_TOKEN}" \
  "https://api.clickup.com/api/v2/task/${PARENT_TASK_ID}")

PARENT_HTTP=$(echo "$PARENT_RESPONSE" | tail -1)
PARENT_BODY=$(echo "$PARENT_RESPONSE" | sed '$d')

if [ "$PARENT_HTTP" != "200" ]; then
  echo "⚠️  Could not fetch task ${PARENT_TASK_ID} (HTTP ${PARENT_HTTP}). Check the ID/URL and your ClickUp access."
else
  PARENT_NAME=$(echo "$PARENT_BODY" | jq -r '.name')
  LIST_ID=$(echo "$PARENT_BODY" | jq -r '.list.id')
  LIST_NAME=$(echo "$PARENT_BODY" | jq -r '.list.name')
fi
```

Don't save parent tasks into `~/.clickup_lists.json` — that file is for lists you reuse across many tasks (sprints/backlogs); a parent task is specific to this one piece of work, not something to pick from a recurring list.

### 7. Choose the task type

ClickUp's task type (what shows as "Task", "Bug", etc. in the UI) is controlled by the `custom_item_id` field, not a tag — resolve it against what this workspace actually has configured, since the set of types (and whether "Bug" even exists) is workspace-specific.

Find the workspace (team) id — most accounts have exactly one, so this is usually a non-question:

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
TEAMS_RESPONSE=$(curl -s -H "Authorization: ${CLICKUP_API_TOKEN}" "https://api.clickup.com/api/v2/team")
TEAM_COUNT=$(echo "$TEAMS_RESPONSE" | jq '.teams | length')
echo "$TEAMS_RESPONSE" | jq -r '.teams[] | "\(.id): \(.name)"'
```

If `TEAM_COUNT` is `1`, use that team's id directly. If more than one, ask via `ask_user` which workspace this list belongs to.

Fetch that workspace's custom task types:

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
CUSTOM_ITEMS=$(curl -s -H "Authorization: ${CLICKUP_API_TOKEN}" \
  "https://api.clickup.com/api/v2/team/${TEAM_ID}/custom_item" \
  | jq -r '.custom_items')

echo "$CUSTOM_ITEMS" | jq -r '.[] | "\(.id): \(.name)"'
```

Present the choice via `ask_user`: always include **Task** (ClickUp's built-in default type — no `custom_item_id` needed for it) plus one option per entry returned above (using each `.name` — e.g. "Bug", "Milestone", whatever this workspace actually has; don't assume "Bug" exists). If `CUSTOM_ITEMS` is empty, "Task" is the only option and there's nothing to ask.

Resolve `CUSTOM_ITEM_ID`: leave unset if "Task" was chosen, otherwise the `.id` of the matching entry.

If "Bug" was chosen here and the description drafted in step 5 wasn't already written with the bug template, redraft it with that template now, before the preview in step 8.

### 8. Preview and confirm

Show the drafted task before creating anything — include the "Subtask of" line only when in subtask mode:

```
📋 ClickUp Task Preview
───────────────────────

List: <list name>
Subtask of: <parent task name> (<parent task url>)
Type: <Task/Bug>
Assignee: <your username>
Title: <title>

Description:
<繁體中文 description>

───────────────────────
```

Use `ask_user` for approval: **Create** / **Edit** / **Abort**. Never call the create endpoint without explicit approval.

### 9. Create the task

Always include `assignees` (yourself, resolved in step 1); include `parent` only when creating a subtask, and `custom_item_id` only when step 7 resolved one (i.e. anything other than the default "Task"):

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
BODY=$(jq -n \
  --arg name "$TITLE" \
  --arg md "$DESCRIPTION" \
  --arg parent "${PARENT_TASK_ID:-}" \
  --arg custom_item_id "${CUSTOM_ITEM_ID:-}" \
  --argjson assignee "$MY_USER_ID" \
  '{name: $name, markdown_content: $md, assignees: [$assignee]}
   + (if $parent == "" then {} else {parent: $parent} end)
   + (if $custom_item_id == "" then {} else {custom_item_id: ($custom_item_id | tonumber)} end)')

TASK_RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST \
  -H "Authorization: ${CLICKUP_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.clickup.com/api/v2/list/${LIST_ID}/task" \
  -d "$BODY")

TASK_HTTP=$(echo "$TASK_RESPONSE" | tail -1)
TASK_BODY=$(echo "$TASK_RESPONSE" | sed '$d')

if [ "$TASK_HTTP" != "200" ]; then
  echo "❌ Failed to create task (HTTP ${TASK_HTTP}):"
  echo "$TASK_BODY" | jq -r '.err // .'
  exit 1
fi

TASK_ID=$(echo "$TASK_BODY" | jq -r '.id')
TASK_URL=$(echo "$TASK_BODY" | jq -r '.url')
```

`markdown_content` is ClickUp's markdown-formatted description field (not `description`, which is plain text only) — using it keeps the headings, bullets, and numbered steps from step 5 rendered properly. Use it for later description updates too, including step 11's PR link. Use the `.url` ClickUp returns rather than reconstructing it — it's `https://app.clickup.com/t/<id>`, not the `www.clickup.com` form `submit-pr` builds manually.

### 10. Offer to start work now (In Progress status)

Direct-instruction mode only — skip this step entirely in from-PR mode (whether or not step 3 found a PR; from-PR mode means work is already done/underway, which doesn't fit "starting work now" — its status handling is covered by step 11's Code Review offer instead).

Use `ask_user`: **Start working on this now?** (Yes/No).

If **No**, skip the rest of this step — the task keeps the list's default status.

If **Yes**, resolve the list's statuses (reusing `LIST_ID` from step 6) and look for one matching "in progress":

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
LIST_STATUSES_JSON=$(curl -s -H "Authorization: ${CLICKUP_API_TOKEN}" \
  "https://api.clickup.com/api/v2/list/${LIST_ID}" \
  | jq -r '.statuses // []')

IN_PROGRESS_MATCHES=$(echo "$LIST_STATUSES_JSON" | jq -r '[.[] | select(.status | ascii_downcase == "in progress")]')
if [ "$(echo "$IN_PROGRESS_MATCHES" | jq 'length')" = "0" ]; then
  IN_PROGRESS_MATCHES=$(echo "$LIST_STATUSES_JSON" | jq -r '[.[] | select(.status | ascii_downcase | contains("progress"))]')
fi
MATCH_COUNT=$(echo "$IN_PROGRESS_MATCHES" | jq 'length')
```

If the `GET /list/${LIST_ID}` call fails or returns no statuses, tell the user this list has no statuses to choose from and skip — the task was already created successfully in step 9, so this must never fail the whole skill.

- If `MATCH_COUNT` is `1`: the single match is the suggested status. Confirm via `ask_user` with it pre-selected as the default choice (**Set to `<matched name>`** / **Choose a different status** / **Skip**).
- If `MATCH_COUNT` is `0` or more than `1` (ambiguous): fall back to listing every status in `LIST_STATUSES_JSON` (`.status` names) via `ask_user`, same manual-picker spirit as `submit-pr`'s status menu, plus a **Skip** option.

Once a status is chosen (the confident match or a manual pick), apply it:

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
curl -s -X PUT \
  -H "Authorization: ${CLICKUP_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.clickup.com/api/v2/task/${TASK_ID}" \
  -d "$(jq -n --arg status "$CHOSEN_STATUS" '{status: $status}')"
```

### 11. Link the ClickUp task and PR (from-PR mode only, when step 3 found a PR)

When step 3 found no PR, skip this section and report the ClickUp → PR return link as deferred to `create-pr`. In direct-instruction mode no PR lookup is performed; if the task is created before its PR, use the same deferred handoff. Pass or retain the task URL when invoking `create-pr`; that skill adds the task URL to the PR description and offers the return link back to this task. When step 3 found a PR, use the existing bidirectional linking and approval flow below.

Linking is bidirectional: add the PR URL to the ClickUp task, and add the ClickUp task URL to the
Azure DevOps PR. Offer both links together after task creation so either record leads back to the
other. Use the canonical user-facing PR URL, not the Azure DevOps REST API URL:

```bash
PR_URL="https://dev.azure.com/<org>/<project-url-encoded>/_git/<repo>/pullrequest/${PR_ID}"
```

Build both updates as additive, idempotent patches. The ClickUp→PR link means the ClickUp task
description contains the PR URL; the PR→ClickUp link means the Azure DevOps PR description contains
the ClickUp task URL. Preserve existing task and PR descriptions; never replace an existing summary
merely to add a link. If a link is already present, do not add a duplicate. If the user approves
only one direction, apply only that direction and report the other as skipped.

#### Add the PR URL to the ClickUp task

Read the task's current Markdown description and prepend the PR link to the top, only when it is
absent. Request `include_markdown_description=true` and read `markdown_description`; send the update
as `markdown_content`, just as in task creation. Reading or writing the plain-text `description`
here would strip the headings and list formatting from the task created in step 9. See ClickUp's
[Get Task](https://developer.clickup.com/reference/gettask) and
[Update Task](https://developer.clickup.com/reference/updatetask) references.

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
TASK_JSON=$(curl -s -H "Authorization: ${CLICKUP_API_TOKEN}" \
  "https://api.clickup.com/api/v2/task/${TASK_ID}?include_markdown_description=true")

TASK_MARKDOWN_AVAILABLE=false
if CURRENT_TASK_DESC=$(printf '%s' "$TASK_JSON" | jq -er '.markdown_description | select(type == "string")'); then
  TASK_MARKDOWN_AVAILABLE=true
  if [[ "$CURRENT_TASK_DESC" == *"$PR_URL"* ]]; then
    NEW_TASK_DESC="$CURRENT_TASK_DESC"
  else
    if [ -n "$CURRENT_TASK_DESC" ]; then
      NEW_TASK_DESC=$(printf 'PR #%s: %s\n\n%s' "$PR_ID" "$PR_URL" "$CURRENT_TASK_DESC")
    else
      NEW_TASK_DESC=$(printf 'PR #%s: %s' "$PR_ID" "$PR_URL")
    fi
  fi
else
  echo "⚠️ Could not read the task's Markdown description; skipping the ClickUp → PR update."
fi
```

This only prepares the proposed task description; do not call `PUT` yet. If the Markdown read failed,
skip the ClickUp → PR description preview and update, report that direction as failed, and continue
with the PR → ClickUp proposal. Do not fall back to the plain-text description or the original draft,
which could lose formatting or overwrite intervening edits.

Fetch the PR's current title/description:

```bash
PR_JSON=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}?api-version=7.1")
CURRENT_TITLE=$(echo "$PR_JSON" | jq -r '.title')
CURRENT_DESC=$(echo "$PR_JSON" | jq -r '.description // ""')
```

Build the patch — additive only, never a full rewrite (that's `summarize-pr`'s job):

```bash
if [[ "$CURRENT_TITLE" == \[#* ]]; then
  NEW_TITLE="$CURRENT_TITLE"
else
  NEW_TITLE="[#${TASK_ID}] ${CURRENT_TITLE}"
fi

if [[ "$CURRENT_DESC" == *"$TASK_URL"* ]]; then
  NEW_DESC="$CURRENT_DESC"
else
  NEW_DESC="Closes ${TASK_URL}

${CURRENT_DESC}"
fi
```

Show the before/after task description, PR title, and PR description. Use `ask_user` to confirm the
ClickUp→PR and PR→ClickUp updates before applying either one. If the title already had a different
`[#...]` bracket, flag that instead of silently overwriting it — ask the user what to do. Never call
either update endpoint without explicit approval.

If `TASK_MARKDOWN_AVAILABLE` is `true`, the user approved the ClickUp→PR direction, and `NEW_TASK_DESC` differs from
`CURRENT_TASK_DESC`, update the task description now:

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
TASK_UPDATE_BODY=$(jq -n --arg md "$NEW_TASK_DESC" '{markdown_content: $md}')
curl -s -X PUT \
  -H "Authorization: ${CLICKUP_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.clickup.com/api/v2/task/${TASK_ID}" \
  -d "$TASK_UPDATE_BODY"
```

Only update the PR when the user approved the PR→ClickUp direction. If a direction was not approved or its link was already present, skip that update and report its status separately.

For the approved PR→ClickUp update, pass the PR description via a HEREDOC (same reasoning as the Azure DevOps Publish section in `create-pr`: it safely preserves markdown, backticks, and quotes):

```bash
PR_UPDATE_BODY=$(jq -n --arg title "$NEW_TITLE" --arg description "$NEW_DESC" \
  '{title: $title, description: $description}')
ado-rest PATCH "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}?api-version=7.1" "$PR_UPDATE_BODY"
```

#### Offer to set Code Review status

After resolving both link directions above, separately offer (its own `ask_user` gate, independent of whether either link was approved) to move the task to a "Code Review"-style status — this reflects that a PR now exists for review, distinct from linking the URLs. Resolve the list's statuses (`LIST_ID` is still in scope from step 6; fetch fresh here since step 10's In Progress offer was skipped in this from-PR branch):

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
LIST_STATUSES_JSON=$(curl -s -H "Authorization: ${CLICKUP_API_TOKEN}" \
  "https://api.clickup.com/api/v2/list/${LIST_ID}" \
  | jq -r '.statuses // []')

CODE_REVIEW_MATCHES=$(echo "$LIST_STATUSES_JSON" | jq -r '[.[] | select(.status | ascii_downcase == "code review")]')
if [ "$(echo "$CODE_REVIEW_MATCHES" | jq 'length')" = "0" ]; then
  CODE_REVIEW_MATCHES=$(echo "$LIST_STATUSES_JSON" | jq -r '[.[] | select(.status | ascii_downcase | contains("review"))]')
fi
CR_MATCH_COUNT=$(echo "$CODE_REVIEW_MATCHES" | jq 'length')
```

If the `GET /list/${LIST_ID}` call fails or returns no statuses, tell the user and skip — this must never undo or block the linking already done above.

- If `CR_MATCH_COUNT` is `1`: confirm via `ask_user` with that status pre-selected as the default (**Set to `<matched name>`** / **Choose a different status** / **Skip**).
- If `CR_MATCH_COUNT` is `0` or more than `1`: fall back to a manual `ask_user` picker over the full status list, plus **Skip**.

Once approved, apply it:

```bash
source "$(command -v local-env)" CLICKUP_API_TOKEN
curl -s -X PUT \
  -H "Authorization: ${CLICKUP_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.clickup.com/api/v2/task/${TASK_ID}" \
  -d "$(jq -n --arg status "$CHOSEN_STATUS" '{status: $status}')"
```

### 12. Show result

```
✅ ClickUp task created
───────────────────────

<title>
Type: <Task/Bug>
Assignee: <your username>
List: <list name>
Status: <default / In Progress / Code Review / unchanged>
URL: <task url>

ClickUp → PR link: yes/no/deferred to create-pr
PR → ClickUp link: yes/no/skipped/deferred to create-pr
```
