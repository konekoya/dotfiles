---
name: address-pr-review
description: 'Fetch Copilot review comments from the Azure DevOps PR for the current branch, critically analyze each one, discuss fixes with the user, then apply approved fixes, run all static checks, and reply to every review comment thread with the outcome.'
---

# Address PR Review

## When to Use

When you need to fetch and address automated Copilot review comments from the Azure DevOps pull request associated with the current Git branch.

## Prerequisites

- `ado-rest` must be on `$PATH` — it is available after `dotfiles/install.sh`.
- The local branch must have a matching PR in Azure DevOps.

Azure DevOps requests use the selected repository profile, not Azure CLI defaults.

## Procedure

### 1. Verify the selected repository profile

Before any PR read or write, validate the selected remote and matching profile:

```bash
ADO_CONTEXT=$(ado-rest context)
REPO=$(printf '%s' "$ADO_CONTEXT" | jq -r '.repository')
BRANCH=$(git --no-pager branch --show-current)
```

If `ado-rest context` fails, stop and report its non-sensitive setup guidance.
Do not print raw remote URLs, switch Azure CLI accounts/subscriptions, or retry
with another profile.

### 2. Use the validated context

`ado-rest context` parses the selected remote, checks fetch/push consistency, and validates the organization profile. Use the parsed repository segment from its JSON output. Do not call `git remote -v` or print remote URLs.

### 3. Find the PR for the current branch

First try the source-ref fast path with the branch URL-encoded. If it returns empty, fall back to listing active PRs and filtering client-side — branch names containing `#` (e.g. ClickUp task IDs like `feat/#86abc123`) must be encoded in the API query.

```bash
BRANCH=$(git --no-pager branch --show-current)
BRANCH_ENCODED=$(jq -rn --arg b "$BRANCH" '$b | @uri')
RESULT=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests?searchCriteria.sourceRefName=refs/heads/${BRANCH_ENCODED}&searchCriteria.status=active&api-version=7.1")
PR_ID=$(printf '%s' "$RESULT" | jq -r --arg branch "refs/heads/${BRANCH}" '[.value[]? | select(.sourceRefName == $branch)][0].pullRequestId // empty')

# The list fallback handles branches containing # and other URL-sensitive characters.
if [ -z "$PR_ID" ]; then
  RESULT=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests?searchCriteria.status=active&api-version=7.1")
  PR_ID=$(printf '%s' "$RESULT" | jq -r --arg branch "refs/heads/${BRANCH}" '[.value[]? | select(.sourceRefName == $branch)][0].pullRequestId // empty')
fi

# A completed PR can still be the one being reviewed; choose the newest exact branch match.
if [ -z "$PR_ID" ]; then
  RESULT=$(ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests?searchCriteria.status=all&api-version=7.1")
  PR_ID=$(printf '%s' "$RESULT" | jq -r --arg branch "refs/heads/${BRANCH}" '[.value[]? | select(.sourceRefName == $branch)] | sort_by(.creationDate) | last | .pullRequestId // empty')
fi
```

If no matching active or completed PR exists, stop and report that no PR was found for the current branch.

### 4. Fetch review threads via REST API

Use `ado-rest` to fetch review threads, then project down to what's needed with `jq` rather than keeping the full response — it carries GUIDs, timestamps, reactions, and other per-thread metadata that isn't useful here:

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

The rest are treated as Copilot review feedback.

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

### 9. Run all static checks

Different repos wire up their quality gates differently — some expose one combined script, others expose separate lint/format/typecheck/test scripts, and some (e.g. Nx monorepos) use different underlying tooling entirely. Rather than assuming one shape, inspect what's actually available in this repo and adapt:

```bash
python3 -c "
import json
scripts = json.load(open('package.json')).get('scripts', {})
print(json.dumps(scripts, indent=2))
"
```

**If a combined gate script exists** (commonly named `vet`, `check`, `verify`, or `validate`), prefer running that alone — it's already set up to run everything in the right order:

```bash
npm run vet 2>&1   # substitute the actual script name found above
```

**Otherwise**, run whichever of these individually exist in `scripts`, in this order, and skip any that aren't present — don't invent a command that isn't defined:

```bash
npm run lint -- --fix 2>&1     # fall back to `npm run lint` if --fix isn't supported
npm run format 2>&1            # prefer a write/auto-fix variant over a *:check variant
npm run typecheck 2>&1
npm run test 2>&1               # prefer a non-interactive/CI variant (e.g. test:ci) if present
```

Tell the user which checks were skipped because no corresponding script existed, so the quality gate's actual coverage is never silently weaker than expected. All checks that DO exist must pass before proceeding to commit — if any fail, fix the issue and re-run.

Where the tool supports scoping to just the changed files (e.g. `nx affected:lint`, `eslint $(git diff --name-only --diff-filter=ACM)`), prefer that over a full-repo run — faster, and less output to sift through. Don't paste raw check output into the conversation: summarize pass/fail per check, and for failures show only the relevant error lines, not the full log.

### 10. Commit the fixes

Stage and commit all changes with a descriptive message:

```bash
git add -A
git commit -m "fix: address PR review comments

- <brief summary of each fix>

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

### 11. Reply to every review comment thread

Every thread collected in step 4 must get a reply — regardless of whether it was fixed, skipped, or deferred. Never leave a review comment unanswered; the reviewer (and anyone reading the PR later) needs to see that each comment was actually considered, not just the ones that resulted in a code change.

**Reply in the same language the reviewer used for that thread.** Detect the language from the original comment's content — per thread, not once for the whole PR, since different threads may have different reviewers writing in different languages. E.g. a thread whose comment is in English gets an English reply; a thread whose comment is in Japanese gets a Japanese reply. Code identifiers, function/variable names, error strings, and other technical terms stay verbatim regardless of reply language — only the surrounding sentence is translated.

**Keep every reply as concise as possible**, in whatever language it's written in. One or two short sentences, no preamble, no restating the original comment, no filler ("Thanks for flagging this", "Great catch", etc.). State only the outcome and the reason. Drop anything the reader can already see from the diff or the thread itself.

Post replies through `ado-rest`; it revalidates the selected profile and keeps auth headers out of curl arguments:

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
