---
name: summarize-pr
description: 'Summarize the current branch''s implementation from local git history/diff into structured sections (Summary, Main Changes, Automated Tests), then update the Azure DevOps PR description. Use when: summarize PR, update PR description, what did this branch do, describe PR changes, fill in PR description.'
---

# Summarize PR

## When to Use

When you need to summarize what the current branch actually implements (from local git, not from an existing PR description) and write that summary into the Azure DevOps PR's description field.

This is the inverse of `address-pr-review`/`pr-comments`: those read *from* the PR, this reads *from local git* and writes *to* the PR description.

## Prerequisites

- `ado-rest` must be on `$PATH` — it is available after `dotfiles/install.sh`.
- Local branch should have commits ahead of its base branch.

Azure DevOps requests use the selected repository profile, not Azure CLI defaults.

## Procedure

### 1. Verify the selected repository profile

```bash
ADO_CONTEXT=$(ado-rest context)
REPO=$(printf '%s' "$ADO_CONTEXT" | jq -r '.repository')
PROJECT=$(printf '%s' "$ADO_CONTEXT" | jq -r '.project')
ORG=$(printf '%s' "$ADO_CONTEXT" | jq -r '.organization')
BRANCH=$(git --no-pager branch --show-current)
```

If `ado-rest context` fails, stop and report its non-sensitive setup guidance. Do not print raw remote URLs or switch Azure CLI accounts.

### 2. Use the validated Azure DevOps context

`ado-rest context` parses the configured remote, verifies its fetch/push pair, and validates the selected organization profile. Use the repository identifier from that JSON for API paths.

### 3. Resolve PR ID for the current branch (if one exists)

Try the fast path, fall back to listing + client-side filtering (branch names with `#` break `--source-branch` server-side filtering):

```bash
BRANCH=$(git --no-pager branch --show-current)
BRANCH_ENCODED=$(jq -rn --arg b "$BRANCH" '$b | @uri')
RESULT=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests?searchCriteria.sourceRefName=refs/heads/${BRANCH_ENCODED}&searchCriteria.status=active&api-version=7.1")
PR=$(printf '%s' "$RESULT" | jq -c --arg branch "refs/heads/${BRANCH}" '[.value[]? | select(.sourceRefName == $branch)][0] // empty')
if [ -z "$PR" ]; then
  RESULT=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests?searchCriteria.status=active&api-version=7.1")
  PR=$(printf '%s' "$RESULT" | jq -c --arg branch "refs/heads/${BRANCH}" '[.value[]? | select(.sourceRefName == $branch)][0] // empty')
fi
PR_ID=$(printf '%s' "$PR" | jq -r '.pullRequestId // empty')
PR_TARGET=$(printf '%s' "$PR" | jq -r '.targetRefName // empty | sub("^refs/heads/"; "")')
PR_TITLE=$(printf '%s' "$PR" | jq -r '.title // empty')
PR_EXISTING_DESCRIPTION=$(printf '%s' "$PR" | jq -r '.description // empty')
```

An empty result here is **not an error** — it just means no PR exists yet (handled in step 8).

### 4. Determine the base/target branch

In order of preference:

1. If a PR was found in step 3, use its `targetRefName` (strip `refs/heads/`).
2. Otherwise, the repo's default branch from `ado-rest GET "/_apis/git/repositories/${REPO}?api-version=7.1" | jq -r '.defaultBranch'` (strip `refs/heads/`).
3. If still ambiguous, ask the user which branch this targets.

### 5. Gather local branch changes

```bash
git --no-pager log <base>..HEAD --oneline
git --no-pager diff <base>...HEAD --stat
```

Read the actual diff content for non-trivial changes — don't trust commit messages alone, they can be stale or misleading relative to the real diff:

```bash
git --no-pager diff <base>...HEAD
```

For large diffs, go file by file and focus on files whose purpose isn't obvious from the stat summary alone.

Also classify the changed files (from the `--stat`/`--name-status` output) into:

- **Test files** — paths matching common heuristics: `*.spec.*`, `*.test.*`, `*.it.*`, `__tests__/`, `test/`, `tests/`, `e2e/`, `cypress/`, `playwright/`, `*Test.cs`, `*_test.go`, or similar per-language conventions.
- **Non-test source files** — recognized code extensions (`.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.cs`, `.java`, `.go`, `.rb`, etc.) that aren't test files, excluding pure config/docs changes (`.md`, `.json`, `.yml`, lockfiles, etc.).

This classification feeds the Automated Tests section below.

### 6. Draft the summary

Always draft the PR description in Traditional Chinese (繁體中文), regardless of the language used in commit messages or existing PR discussion. Section headings (`## 摘要`, `## 主要變更`, `## 自動化測試`) and prose are in Chinese; code identifiers, file paths, function/variable names, and error strings stay verbatim in their original form.

Organize the PR description into these sections:

#### **Summary** (1–2 sentences)
Core purpose and impact. What does this branch accomplish? Keep it concise — the reader should understand the goal in one read.

#### **Main Changes** (grouped bullets)
Grouped logically by domain/layer (feature/fix/refactor/tests/docs as applicable), from the *implementation's perspective* — describe what the code now does, not a verbatim replay of commit messages. Subheadings OK if groups are substantial:

```markdown
### ServiceName (if applicable)
- Change 1
- Change 2
```

Keep bullets short and scannable; no filler. Testing-related bullets (test file coverage) belong only in the Automated Tests section below — never repeat them under a Main Changes group.

#### **Automated Tests** (bullet or paragraph)

From the test-file classification above: for each test file added or modified in the diff, one bullet with the file name and a one-line description of what it covers, labeled by type inferred from its path/naming convention — UT for spec/jest/karma/vitest-style unit tests, IT for `*.it.*`/integration dirs, E2E for playwright/cypress/e2e dirs. Omit this section entirely if no test files changed. This section only summarizes test coverage — every PR is already gated by CI, so don't include run status, pass counts, or manual test steps.

**Missing-test flag**: if the diff has non-test source changes but zero test files changed, append one soft, informational note, e.g. `⚠️ 此 PR 修改了程式碼但未新增或修改測試（UT/IT/E2E）。` — this does not block or pause the flow, it's just part of the drafted description shown to the user in the confirmation step.

## 摘要
把 Website 物件的預覽流程從 iframe embed 改為串接後端 FileAsset 截圖 pipeline，讓 canvas 上所有 Website 物件走同一套 fileId/screenshotUrl 資料流。

## 主要變更
**WebsiteScreenshotService**
- 封裝截圖 API 呼叫與輪詢；同一 URL 的並發請求共用同一個 in-flight Observable
- 避免 data URL 長時間累積

**Add Website 彈窗**
- 輸入 URL 後即時顯示截圖預覽（loading/ready/failed 三態）
- 確定新增時重用預覽已取得的 fileId/screenshotUrl，不重複發起截圖

## 自動化測試
- 新增 `website-screenshot.service.spec.ts`（UT）：涵蓋輪詢邏輯與 in-flight Observable 共用
- 新增 `color-picker.it.ts`（Playwright E2E）：涵蓋 Add Website 彈窗的截圖預覽三態
```

### 7. Confirm with the user

Show the drafted description and ask for confirmation before writing anywhere. Offer to revise or regenerate if the user wants changes. Never write to the PR without explicit approval.

### 8. Write the description

**If a PR already exists** (step 3 found one):

Ask whether to **replace** or **append to** the existing description — an existing description may carry a template or checklist worth preserving. Default suggestion: if the existing description is non-empty, append the drafted summary under a `## Summary` heading; if empty, just set it directly.

If the existing description contains a block between `<!-- risk-assessment:start -->` and `<!-- risk-assessment:end -->` (written by `create-pr`), keep that block byte-for-byte, including its ticked checklist boxes, as the last thing in the description, even on **replace** or append: the sections this skill drafts go above it. Only those sections are replaced. Do not score risk here and do not rewrite the block, even when it is in an older format; point the user to `create-pr` to refresh a stale score or bring the block to the current format. If the existing description has a `## 測試` heading, the section drafted here uses `## 自動化測試` instead.

```bash
DESCRIPTION_BODY=$(jq -n --arg description "$PR_DESCRIPTION" '{description: $description}')
ado-rest PATCH "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}?api-version=7.1" "$DESCRIPTION_BODY"
```

**If no PR exists yet**: don't create one here — that's `create-pr`'s job. Tell the user the drafted summary is ready and point them to `create-pr` (offer to hand off directly), rather than duplicating PR-creation logic.

### 9. Confirm success

Print the PR URL and the final description state using the organization and project returned by `ado-rest context`:

```
https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<pr-id>
```
