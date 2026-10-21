---
name: babysit-pr-checks
description: 'Get an open Azure DevOps PR to a fully green, mergeable state: resolve merge conflicts with the target branch, fetch and address Copilot review comments (analyze, discuss, fix, reply to every thread), then discover and run local quality checks (format, lint, typecheck, unit tests), fix failures, push, then watch remote CI/build status and drill into failures — including integration tests that can only run in the pipeline — fixing and re-pushing until everything passes or a fix needs your input. Before declaring done, re-checks for new review comments that arrived from later pushes and fills in a missing PR description via summarize-pr. Use whenever a PR has merge conflicts, review comments, and/or failing or pending checks and you want to stop manually babysitting it.'
argument-hint: '[PR_ID]'
---

# Babysit PR Checks

## When to Use

When a PR is open for the current branch and you want it pushed to a fully green, mergeable state without manually watching it — merge conflicts resolved, Copilot review comments addressed and replied to, local checks, a push, and the remote CI pipeline, looped until everything passes or a failure needs your judgment. Before declaring the PR ready for review, it also re-checks for any review comments that arrived after later pushes and fills in a missing PR description.

For review-comment handling only (no CI babysitting), use `address-pr-review` instead.

## Prerequisites

- `ado-rest` must be on `$PATH` — it is available after `dotfiles/install.sh`.
- The local branch must have a matching PR in Azure DevOps.
- `pr-status` (this repo's `scripts/pr-status`) must be on `$PATH` — it is, once `dotfiles/install.sh` has been run.

Azure DevOps requests use the selected repository profile, not Azure CLI defaults.

## Procedure

### 1. Verify the selected repository profile

```bash
ADO_CONTEXT=$(ado-rest context)
REPO=$(printf '%s' "$ADO_CONTEXT" | jq -r '.repository')
PROJECT=$(printf '%s' "$ADO_CONTEXT" | jq -r '.project')
ORG=$(printf '%s' "$ADO_CONTEXT" | jq -r '.organization')
REMOTE=$(printf '%s' "$ADO_CONTEXT" | jq -r '.remote')
BRANCH=$(git --no-pager branch --show-current)
```

If this fails, stop and report its non-sensitive setup guidance. Do not print raw remote URLs or switch Azure CLI accounts.

### 2. Find the PR in the validated repository

`ado-rest context` validates the selected fetch/push remote pair and organization profile.

If an argument was given (`babysit-pr-checks <PR_ID>`), use that PR ID directly instead of the branch-based lookup below.

```bash
PR_ID="${1:-}"
if [ -z "$PR_ID" ]; then
  BRANCH_ENCODED=$(jq -rn --arg b "$BRANCH" '$b | @uri')
  RESULT=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests?searchCriteria.sourceRefName=refs/heads/${BRANCH_ENCODED}&searchCriteria.status=active&api-version=7.1")
  PR_ID=$(printf '%s' "$RESULT" | jq -r --arg branch "refs/heads/${BRANCH}" '[.value[]? | select(.sourceRefName == $branch)][0].pullRequestId // empty')
  if [ -z "$PR_ID" ]; then
    RESULT=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests?searchCriteria.status=active&api-version=7.1")
    PR_ID=$(printf '%s' "$RESULT" | jq -r --arg branch "refs/heads/${BRANCH}" '[.value[]? | select(.sourceRefName == $branch)][0].pullRequestId // empty')
  fi
fi
```

If no matching PR is found, stop and tell the user this skill needs an already-open PR (use `submit-pr` or `create-pr` first).

### 3. Check for merge conflicts

Fetch the PR's target branch and merge status:

```bash
PR_META=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}?api-version=7.1")
TARGET=$(printf '%s' "$PR_META" | jq -r '.targetRefName | sub("^refs/heads/"; "")')
MERGE_STATUS=$(printf '%s' "$PR_META" | jq -r '.mergeStatus // "unknown"')
```

If `MERGE_STATUS` is `succeeded`, there's nothing to resolve — skip to step 4.

Otherwise (`conflicts`, or anything else that isn't a clean merge), resolve locally:

```bash
git fetch "$REMOTE" "$TARGET"
git merge FETCH_HEAD
```

List conflicted files:

```bash
git --no-pager diff --name-only --diff-filter=U
```

For each conflicted file: read it, understand both sides of the `<<<<<<<` / `=======` / `>>>>>>>` markers, and resolve by combining the intent of both changes rather than blindly taking "ours" or "theirs". If a conflict is ambiguous — both sides changed the same logic in incompatible ways and the correct resolution isn't clear from context — **stop and ask the user** rather than guessing.

Once every conflict marker is gone:

```bash
git add <resolved files>
git commit -m "merge: resolve conflicts with <target>"
```

Don't push yet — this merge commit rides along with review-comment fixes and check fixes into the single push checkpoint in step 11, so the user is asked for push confirmation once, not repeatedly.

If `git merge` reports nothing to merge (already up to date) but `mergeStatus` still isn't `succeeded`, or if conflicts remain after your edits, re-check with `git --no-pager diff --name-only --diff-filter=U` before committing.

### 4. Fetch review threads

Fetch PR threads through `ado-rest`, then project down to what is needed with `jq` rather than retaining the full response — it carries GUIDs, timestamps, reactions, and other per-thread metadata that isn't useful here:

```bash
THREADS=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}/threads?api-version=7.1")
printf '%s' "$THREADS" | jq -c '
    .value[]
    | select(.isDeleted != true and (.comments | map(select(.isDeleted != true and .commentType != "system")) | length) > 0)
    | {
        id,
        status,
        filePath: .threadContext.filePath,
        line: (.threadContext.rightFileStart.line // .threadContext.leftFileStart.line),
        comments: [.comments[] | select(.isDeleted != true and .commentType != "system") | {author: .author.displayName, content}]
      }
  '
```

This already drops deleted threads, system comments, and empty threads. Skim the remaining, already-compact threads for two more exclusions that aren't safe to bake into the `jq` filter (no reliable field to key on):

- Closed/resolved threads (unless specifically asked to review them)
- Coverage report threads (from "Azure Pipelines Test Service")

The rest are treated as Copilot review feedback. `ado-rest` resolves the selected profile for every request.

**If no threads remain after filtering**, note that there are no review comments to address and skip straight to step 9.

Keep an in-session record of `{thread_id: comment_count}` for every thread seen here — not a persisted file, just bookkeeping for this run. It's updated each time step 12 replies to a thread, and re-checked by step 15 to detect comments that show up after this initial fetch.

### 5. Read and analyze each affected file

For every distinct file mentioned in a review comment (read each file once, even if several comments target it):

1. Read the full source file to understand the context.
2. Look for the project's actual conventions rather than assuming a fixed doc path — check for a `docs/` folder, `README.md`, `CONTRIBUTING.md`, or repo-level agent instructions (e.g. `AGENTS.md`, `.github/copilot-instructions.md`, or a custom instructions block) if present, and follow whatever conventions they define.
3. Check for similar patterns in the codebase (e.g., does the same "issue" exist elsewhere and is it intentional?).

### 6. Critically evaluate each comment

For **each** review comment, provide a verdict with reasoning:

| Verdict      | When to use                                                                                                                       |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| **✅ Fix**   | The comment identifies a real bug or a clear violation of documented project conventions                                          |
| **❌ Skip**  | The reviewer is factually wrong, the comment is about code not changed in this PR, or the suggestion would introduce worse issues |
| **⚠️ Defer** | Valid concern but out of scope for this PR (note it for a follow-up)                                                              |

Be critical — do not blindly accept every review comment. Check:

- Is the reviewer's claim factually accurate against the actual code?
- Does the project's style guide or lint config actually enforce this rule?
- Is the suggested fix correct and complete?
- Would the fix introduce new issues or break existing tests?
- Is this a real bug or just a style preference?

Present all findings in a summary table to the user with severity, file, issue, and your verdict.

### 7. Discuss with the user

**Always ask the user** before applying fixes. Present options:

- Fix all valid issues
- Fix only medium/high severity (bugs)
- Let the user pick individually

Wait for the user's decision before proceeding.

### 8. Apply the approved fixes

Make precise, surgical changes to each file. For each fix:

1. Edit only the specific lines that need changing.
2. Ensure the fix matches the project's conventions (see step 5).
3. Update barrel exports (`index.ts`) if new types/exports are added.

Don't run static checks or commit yet — review fixes flow into the local check loop and push checkpoint below, alongside any check fixes, so both land in one pass.

### 9. Discover the local quality checks

Different repos wire up their quality gates differently — inspect what's actually available rather than assuming a shape:

```bash
python3 -c "
import json
scripts = json.load(open('package.json')).get('scripts', {})
print(json.dumps(scripts, indent=2))
"
```

If a combined gate script exists (`vet`, `check`, `verify`, `validate`), prefer it. Otherwise run whichever of format/lint/typecheck/test exist individually, in that order, and skip (and later report) any that don't exist — don't invent a command that isn't defined.

Also look for an integration-test script by name pattern (`test:integration`, `test:it`, `integration-test`, `e2e`, etc.). Integration tests often need a deployed environment/DB and can't run locally — if attempting it locally fails with what looks like a connectivity/environment error rather than a real assertion failure, don't treat that as something to fix. Skip it locally and note it'll be validated by the remote pipeline in step 13.

### 10. Run the local check loop

For each check that exists, in priority order (later checks depend on earlier ones being clean):

1. **Format** — run the auto-fix/write variant if one exists.
2. **Lint** — auto-fix where safe, then fix remaining issues manually.
3. **Typecheck** — fix compilation errors.
4. **Unit tests** — fix or update failing tests.

This also validates any merge-conflict resolution from step 3 and review-comment fixes from step 8, since they're already sitting in the working tree.

After fixing a check, re-run just that check to confirm before moving to the next one. This is a **repeat-until-clean loop, capped at 5 attempts per check** — if a check still fails after 5 fix-and-rerun cycles, stop and hand that specific failure to the user instead of continuing to guess.

Once every check that exists is clean, do one final full re-run of all of them together as a sanity pass before moving on.

### 11. Push checkpoint

Show a concise summary of what was fixed — covering merge-conflict resolution (step 3), review-comment fixes (step 8), and check fixes (step 10), or that everything was already clean — and **stop and ask for explicit confirmation before every `git push`** — including the first one. Never push without asking first, and never force-push.

```bash
git add -A
git commit -m "fix: address PR review and get checks passing

<brief summary of what was fixed>

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

### 12. Reply to every review comment thread

Every thread collected in step 4 must get a reply — regardless of whether it was fixed, skipped, or deferred. Never leave a review comment unanswered; the reviewer (and anyone reading the PR later) needs to see that each comment was actually considered, not just the ones that resulted in a code change. Skip this step entirely if step 4 found no threads.

**Reply in the same language the reviewer used for that thread.** Detect the language from the original comment's content — per thread, not once for the whole PR, since different threads may have different reviewers writing in different languages. E.g. a thread whose comment is in English gets an English reply; a thread whose comment is in Japanese gets a Japanese reply. Code identifiers, function/variable names, error strings, and other technical terms stay verbatim regardless of reply language — only the surrounding sentence is translated.

**Keep every reply as concise as possible**, in whatever language it's written in. One or two short sentences, no preamble, no restating the original comment, no filler ("Thanks for flagging this", "Great catch", etc.). State only the outcome and the reason. Drop anything the reader can already see from the diff or the thread itself.

Post a reply on each thread via `ado-rest`:

```bash
REPLY_BODY=$(jq -n --arg content "$REPLY" '{content: $content, commentType: "text"}')
ado-rest POST "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}/threads/${THREAD_ID}/comments?api-version=7.1" "$REPLY_BODY" >/dev/null
```

Tailor the reply message to the verdict reached in step 6. Examples below are shown in English for illustration only — the actual reply is written in that thread's reviewer language, per the rule above:

| Verdict      | Reply should (1-2 sentences max)                                                                  | Example                                                                 |
| ------------ | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| ✅ Fixed    | State the change, note it's in the latest commit                                                    | "Fixed — added null check. In latest commit."                          |
| ❌ Skipped  | State why, pointing to the specific code/convention that makes it inapplicable                       | "Skipped — `foo()` already validates this at line 42."                 |
| ⚠️ Deferred | State it's valid but out of scope, and where it'll be tracked                                        | "Valid point, out of scope here. Tracked in TICKET-123."                |

Optionally also reflect the outcome in the thread's `status` field (`fixed`, `wontFix`, `closed`, etc.) with a `PATCH` to the thread itself:

```bash
THREAD_UPDATE=$(jq -n --arg status fixed '{status: $status}')
ado-rest PATCH "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}/threads/${THREAD_ID}?api-version=7.1" "$THREAD_UPDATE" >/dev/null
```

Do this for every thread from step 4, including ones with a ❌ Skip or ⚠️ Defer verdict — not just the ones that resulted in a code change.

After replying to a thread, update the in-session `{thread_id: comment_count}` record from step 4 with that thread's current comment count (including your new reply), so step 15 can tell a thread apart from one that picked up a fresh comment afterward.

### 13. Watch remote CI

Run the watch in the background rather than polling turn-by-turn:

```bash
pr-status --watch
```

Invoke this via the Bash tool with `run_in_background: true`. Don't sleep or re-check manually — a completion notification arrives automatically when the watch exits, either because the PR's status resolved (succeeded/failed) or because it hit its internal ~9-minute cap while still pending. In the latter case, just invoke `pr-status --watch` again in the background and continue waiting.

While waiting, tell the user briefly that CI is being watched in the background and move on — don't narrate every internal poll.

### 14. Diagnose and fix remote failures

If `pr-status` reports a failure, its output already includes the failing job/task name and a capped, grep-filtered log excerpt (never the full log — this PR's status surface only exposes one aggregate build state, so the per-check detail comes entirely from that drill-down).

1. Summarize the failure to the user in a sentence or two: which check, what the excerpt shows.
2. Propose a fix.
3. Apply it, then re-run the specific local check that corresponds to the failure (not the full suite) to sanity-check before pushing again.
4. Return to step 11 (push checkpoint).

**Track repeats.** If the same named check fails again after a fix that was already applied and pushed, for the 3rd consecutive time, say so explicitly — e.g. "this doesn't look like a quick fix, want me to keep going or take it from here?" — rather than silently continuing to guess.

If `pr-status` can't identify a specific failed job (e.g. no `targetUrl`, or the build failed with no individual job marked failed), say so and give the user the PR link rather than guessing at a fix blind.

### 15. Final review-comment gate

CI succeeding doesn't mean the review is settled — every push since step 4 (merge-conflict commit, review fixes, check fixes, CI-failure fixes) can have triggered a fresh round of Copilot review, or a human reviewer may have commented while this was running. Once `pr-status` reports success, re-check before declaring anything done:

1. Re-run the exact same `ado-rest` fetch-and-filter request from step 4 (same `jq` filter — drop deleted/system/empty threads, skim out closed/resolved and coverage-report threads).
2. Compare against the in-session `{thread_id: comment_count}` record from steps 4/12:
   - A thread ID not in the record → brand-new thread.
   - A thread ID in the record whose current comment count is higher than what's recorded → a follow-up landed after the last reply.
   - Otherwise → already handled, ignore it.
3. **Nothing new:** continue to step 16.
4. **Something new:** handle just those threads through the normal pipeline — step 5 (read affected files), step 6 (evaluate + verdict), step 7 (discuss with the user), step 8 (apply approved fixes), step 9/10 (local checks, only if a fix touched code), step 11 (push checkpoint — same confirm-before-push rule as always), step 12 (reply to these threads and update the tracked record), then step 13 (re-watch CI, since a new push just happened). Once CI resolves again, re-run this gate from the top rather than falling through.
5. **Cap at 3 gate passes.** If a 4th pass would still find something new, stop and tell the user directly — e.g. "New review comments keep appearing after each push — want me to keep going or take it from here?" — rather than looping indefinitely.

### 16. Ensure the PR has a description

Runs once step 15 finds nothing left to address.

1. Check the PR's description — reuse `PR_META` from step 3 if it is still trustworthy, or re-fetch it:
   ```bash
   PR_META=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}?api-version=7.1")
   PR_DESCRIPTION=$(printf '%s' "$PR_META" | jq -r '.description // empty')
   ```
2. Treat empty, missing, or whitespace-only as "no description" (a bare placeholder counts as missing too).
3. **Already has one:** skip silently — no need to bring this to the user.
4. **Missing:** tell the user the PR has no description, then invoke the `summarize-pr` skill to draft and write one — don't duplicate its logic here. Hand it the context already resolved in this run (org, project, repo, PR id, branch, target branch) so it doesn't have to re-derive its own steps 1–4. `summarize-pr`'s own step 7 (confirm with the user before writing) still applies.
5. This doesn't loop back into the CI-watch/comment-gate cycle — a description-only change doesn't affect checks or review threads.

### 17. Done

Report a short final summary and stop — review comments addressed (counts fixed/skipped/deferred, plus any extra rounds caught by step 15), what was fixed across the session for CI, and whether step 16 filled in a missing PR description — then give the PR link. The PR is ready for human review.
