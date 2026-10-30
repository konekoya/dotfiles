# PR Risk Assessment

Score the PR so a reader can tell whether a human must review it and how deeply. The score is advisory: it never blocks publishing, and it does not replace branch policies, CODEOWNERS, or required reviewers. Base it on the diff from shared step 4, not on commit messages.

## Dimensions

Rate each dimension `0` (not touched), `1` Low, `2` Medium, or `3` High. A trigger sets a **minimum**; raise the rating when the actual change is worse, never lower it below a matched trigger.

| Dimension | Minimum rating when the diff... |
| --- | --- |
| Security | 3: changes authentication, authorization, session or token handling, crypto, secret handling, CORS/CSP, or deserialization. 2: adds or reads user input without visible validation, logs possibly sensitive data, adds or upgrades a runtime dependency. 1: touches security-adjacent code without changing behavior. |
| UI regression | 3: changes a shared component, global style, theme token, layout shell, or routing used by many screens. 2: changes visible markup, styles, or interaction on one screen. 1: copy, icon, or spacing tweaks. |
| Data and migration | 3: changes a schema, adds a migration, runs a backfill, or deletes or rewrites stored data irreversibly. 2: changes queries, indexes, or serialization of stored data. 1: read-only data access changes. |
| API and contract | 3: removes or renames a public API field, endpoint, event, or CLI flag, or changes its meaning. 2: adds required input or changes defaults or error shapes. 1: additive, optional changes. |
| Blast radius | 3: changes core or shared code with many dependents, or a cross-module refactor. 2: changes a module used by several features. 1: isolated change with few callers. |
| Business logic | 3: changes money, tax, billing, permissions, scheduling, concurrency, or state-machine logic. 2: changes branching or calculation in a user-facing flow. 1: simple, local conditions. |
| Performance | 3: changes a hot path, adds per-item queries or I/O in a loop, or grows startup or bundle size noticeably. 2: adds work on a common path. 1: negligible. |
| Ops and rollback | 3: changes pipelines, deploy or infrastructure config, environment variables, or ships behavior that cannot be reverted by reverting the PR. 2: changes build or Docker config, or removes a feature flag. 1: tooling or docs-adjacent config. |

## Overall level

`overall = max(dimension ratings)`, then apply modifiers in order, keeping the result within 0–3:

- **Test gap, +1**: non-test source changed with no test changed. Reuse the classification from `summarize-pr` (test paths versus recognized source extensions). Skip this when the max is already 3.
- **Mechanical, −1**: only lockfile, generated code, pure rename or move, or formatting changes, verified from the diff. Never apply this to a dimension rated 3.

Use the max, not an average: one severe risk must not be diluted by many quiet dimensions.

| Level | Meaning | Human review |
| --- | --- | --- |
| L0 | Docs, comments, or mechanical changes | CI is enough; skim the summary |
| L1 | Small, low-impact change | Standard review of the diff by one reviewer |
| L2 | Meaningful risk in named areas | Focused review of the listed files; verify the listed behavior by hand (open the screen, run the migration, exercise the endpoint) |
| L3 | High-impact or hard to revert | Domain-expert review plus a walkthrough; confirm a rollback plan before merging |

## Output

Include only dimensions rated 1 or higher, highest first. Each finding states the evidence (`path:line`) and why it is risky, not what to do about it: the actions live only in the checklist below, so nothing is listed twice. Name the modifiers applied. Collapse the rest into one line. Record the scored commit: `git rev-parse --short HEAD`. When the head commit moves after scoring (a new push in update mode), score again; never carry a stale level over.

An L3 PR may suggest a reviewer in the preview, but never add or change reviewers automatically. Before showing the preview, check that nothing follows `<!-- risk-assessment:end -->` and that the block does not appear anywhere else in the description. The block is the only output: do not add labels, statuses, or comments.

### Checklist

Add a checklist for the PR owner, who does the manual QA and review. The PR counts as checked only when every box is ticked. Build it from:

- Every dimension rated 2 or 3: one item per distinct behavior to verify, so each can be ticked on its own. Rating 1 gets no item.
- Each applied modifier that asks for work: test gap becomes "add a test, or confirm why none is needed".
- L3: an item to confirm the rollback plan.

Each item is one concrete action with an observable pass condition, prefixed with its dimension: `- [ ] UI regression: <what to do and what to expect>`. Do not name files, paths, or identifiers in an item; the owner tests behavior, and the paths already sit in the finding above. A behavior change that is deliberate still gets an item to confirm the owner accepts it. Omit the section when no item qualifies; never emit an empty heading.

Never tick a box yourself. Tick one only when the user says they did that check. In update mode, regenerate the checklist from the new score. Keep a box ticked only when the item text is unchanged and the files of its finding's evidence are unchanged since the previous `scored at` commit (`git diff <old>..HEAD -- <paths>` is empty); otherwise reset it to unticked, because the code it vouched for has moved.

### Language and markers

Language follows the description. Azure DevOps default is Traditional Chinese with the `## 風險評估` and `### PR 檢查清單` headings; GitHub follows the user, repository, or English with `## Risk Assessment` and `### PR Checklist`. Paths and identifiers stay verbatim. In Chinese output, write the closing no-risk line entirely in Chinese too, using these names: Security 資安, UI regression UI 迴歸, Data and migration 資料, API and contract API, Blast radius 影響範圍, Business logic 業務邏輯, Performance 效能, Ops and rollback 維運. Use `未發現風險：資安、資料、API、效能、維運。` rather than an English `No risk found:` line.

Wrap the section in markers so later runs and other skills can find and replace it without touching the rest of the body:

```markdown
<!-- risk-assessment:start -->
## Risk Assessment
**Overall: L2 (focused review)** · scored at `abc1234`

- Security, 3: `auth/guard.ts:40-80` changes the permission check; access could be widened.
- UI regression, 2: shared `Button` styles change on the main screens.
- Modifier: +1 test gap (source changed, no tests changed).

No risk found: data, API, blast radius, business logic, performance, ops.

### PR Checklist
- [ ] Security: confirm a user without the role is still denied
- [ ] UI regression: open the main screens and compare the buttons against the previous build
- [ ] Test gap: add a test for the guard, or note why none is needed
<!-- risk-assessment:end -->
```

The Chinese form of the same block:

```markdown
<!-- risk-assessment:start -->
## 風險評估
**Overall: L2（重點審查）** · scored at `abc1234`

- Security, 3：`auth/guard.ts:40-80` 變更權限檢查，存取範圍可能被放寬。
- UI regression, 2：共用 `Button` 樣式變更，影響主要畫面。

未發現風險：資料、API、影響範圍、業務邏輯、效能、維運。

### PR 檢查清單
- [ ] Security：確認沒有該角色的使用者仍被拒絕
- [ ] UI regression：開啟主要畫面，與前一版比對按鈕外觀
<!-- risk-assessment:end -->
```

Placement: always the very end of the description, below the last section, separated by a blank line. For Azure DevOps, below `## 測試`. For GitHub, below the last body section; when a PR template applies, append the block after the template's last section and leave the template untouched. In update mode, regenerate the block and place it at the end, removing the old block wherever it was (older PRs carry it at the top).
