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

Include only dimensions rated 1 or higher, highest first, each with evidence (`path:line`) and the concrete check a human should do. Name the modifiers applied. Collapse the rest into one line. Record the scored commit: `git rev-parse --short HEAD`. When the head commit moves after scoring (a new push in update mode), score again; never carry a stale level over.

An L3 PR may suggest a reviewer in the preview, but never add or change reviewers automatically. The block is the only output: do not add labels, statuses, or comments.

Language follows the description. Azure DevOps default is Traditional Chinese with the `## 風險評估` heading; GitHub follows the user, repository, or English with `## Risk Assessment`. Dimension names, paths, and identifiers stay verbatim.

Wrap the section in markers so later runs and other skills can find and replace it without touching the rest of the body:

```markdown
<!-- risk-assessment:start -->
## Risk Assessment
**Overall: L2 (focused review)** · scored at `abc1234`

- Security, 3: `auth/guard.ts:40-80` changes the permission check. Confirm access is not widened.
- UI regression, 2: shared `Button` styles change. Open the main screens and compare.
- Modifier: +1 test gap (source changed, no tests changed).

No risk found: data, API, blast radius, business logic, performance, ops.
<!-- risk-assessment:end -->
```

Placement: for Azure DevOps, directly below the `Closes <ClickUp URL>` line (or at the top when that line is absent) and above `## 摘要`. For GitHub, above the first body section; when a PR template applies, insert the block above the template's first heading and leave the template untouched. In update mode, replace the existing marked block; if none exists, insert a new one.

