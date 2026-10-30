---
name: create-pr
description: 'Push the current branch and create or update a GitHub or Azure DevOps PR. Detect the provider from the selected Git remote, run repository quality checks, and score review risk with a PR checklist, and publish through gh or the shared Azure DevOps REST helper. Use when: create PR, open pull request, update PR, 建 PR, 發 PR.'
---

# Create or Update a Pull Request

Use the host's available question tool wherever this procedure says `ask_user`; if none is available, ask in chat. Honor choices and authorization already given in the session. An optional skill argument supplies the PR title.

## Provider routing

Use the repository's `azure-devops.remote` setting, otherwise `origin`; assign it to `PR_REMOTE`. Inspect repository state and the selected remote without printing its URL, which could contain credentials:

```bash
git rev-parse --is-inside-work-tree
git status --porcelain
PR_REMOTE=$(git config --local --get azure-devops.remote || printf '%s' origin)
```

For Azure DevOps, run `ado-rest context` before any PR reads or writes. It validates the selected fetch/push pair and organization profile, and returns safe parsed identifiers. For GitHub, inspect the selected URL in memory and never print it; do not expose URL userinfo in tool output. Recognize SSH and HTTPS URLs, including `ssh://`:

| Remote host | Provider reference |
| --- | --- |
| `github.com` | [GitHub](references/github.md) |
| `dev.azure.com`, `ssh.dev.azure.com`, or `*.visualstudio.com` | [Azure DevOps](references/azure-devops.md) |

Read only the selected provider reference. Use the validated context for Azure DevOps API paths; do not let Azure CLI defaults select an account or organization. If the remote is missing, unsupported, or has conflicting fetch/push destinations, ask the user to select the intended repository before publishing. A GitHub fork with an upstream base requires an explicit base repository and head repository; follow the fork guidance in the GitHub reference.

**GitHub skips ClickUp entirely:** no task lookup or creation, task-ID title brackets, ClickUp prompts, backlinks, or task status changes. Do not load Azure instructions or check Azure authentication for GitHub, even when ClickUp environment variables or a `feat/#<taskId>` branch are present. Azure DevOps retains the optional integration with existing ClickUp tasks; this skill never creates a ClickUp task.

## Shared procedure

### 1. Authenticate and check branch state

Follow the selected reference's authentication checks. Stop on missing tooling or authentication and provide the relevant setup command; do not attempt another provider's login.

```bash
BRANCH=$(git branch --show-current)
git status --porcelain
```

If HEAD is detached, stop until a named branch is selected. If on `develop`, `main`, `master`, or the repository's configured default branch, use `ask_user` to select a feature/fix branch and create it with `git checkout -b`. Only on Azure DevOps, prefill `feat/#<taskId>` when the user already supplied a ClickUp task ID. Carry existing uncommitted changes to the new branch and refresh `BRANCH` after switching.

If the tree is dirty, offer **Commit changes** (use `create-git-commit`), **Stash changes** (`git stash push -u -m "create-pr auto-stash"`), or **Abort**. Do not continue with a dirty tree. Report any stash at the end; do not silently restore it over later changes.

### 2. Find an existing PR

Use the selected reference's lookup for the exact source repository and branch. A failed lookup is an error, not evidence that no PR exists. If multiple open PRs match, ask which to update. Store its ID/number, URL, title, description, target branch, draft state, and reviewers as defaults. Create only when a successful lookup finds none.

### 3. Run repository quality checks

Read the repository's agent instructions, contributor guide, CI configuration, and build files. Use its package manager and defined commands. For Node projects, inspect `package.json`; prefer an existing combined gate such as `vet`, `check`, or `verify`, otherwise run the defined format, lint, typecheck, and test commands. For shell, Python, or other projects, use their documented checks. Report missing check categories; do not invent npm scripts or require `package.json` for other languages.

- Every applicable check must pass before publishing. Fix failures and re-run the affected checks.
- If checks change files, review the diff and commit only the relevant files in a new commit. Preserve unrelated changes and history; amend only when explicitly requested.

### 4. Resolve the target and inspect changes

Use the remote for the base repository (which may differ from the push remote for a GitHub fork), call it `BASE_REMOTE`; for Azure DevOps it is `PR_REMOTE`. Choose the target in this order: explicit user choice, existing PR target, documented repository target, remote default branch. Inspect `refs/remotes/$BASE_REMOTE/HEAD`; if missing, use the selected provider's default-branch lookup. If no default can be determined, inspect available `main`, `master`, and `develop` refs for that remote, using the sole candidate or asking among multiple candidates.

Prefer the base remote's remote-tracking ref:

```bash
if git rev-parse --verify "refs/remotes/$BASE_REMOTE/$TARGET_BRANCH^{commit}" >/dev/null 2>&1; then
  BASE_REF="refs/remotes/$BASE_REMOTE/$TARGET_BRANCH"
elif git rev-parse --verify "refs/heads/$TARGET_BRANCH^{commit}" >/dev/null 2>&1; then
  BASE_REF="refs/heads/$TARGET_BRANCH"
else
  echo "Target branch is unavailable; fetch it before continuing." >&2
  exit 1
fi
```

If the ref is missing or stale, fetch the intended base remote and target before reviewing. Confirm the branch has changes relative to the target.

Inspect the history and actual diff:

```bash
git --no-pager log "$BASE_REF"..HEAD --oneline
git --no-pager diff "$BASE_REF"...HEAD --stat
git --no-pager diff "$BASE_REF"...HEAD
```

Read the actual diff content for non-trivial changes — don't trust commit messages alone, they can be stale or misleading relative to the real diff. For large diffs, go file by file and focus on files whose purpose isn't obvious from the stat summary alone.

### 5. Draft PR details

Pick the most accurate prefix, same table the `create-git-commit` skill uses:

| Type        | When to use                                                            |
| ----------- | ---------------------------------------------------------------------- |
| `feat:`     | A new feature for the user (not a new build script feature).           |
| `fix:`      | A bug fix for the user.                                                |
| `docs:`     | Documentation-only changes.                                            |
| `style:`    | Formatting, missing semicolons, whitespace; no production code change. |
| `refactor:` | Refactoring production code (e.g., renaming a variable).               |
| `perf:`     | A code change that improves performance.                               |
| `test:`     | Adding missing tests or correcting existing tests.                     |
| `chore:`    | Updating grunt tasks, tooling, etc.; no production code change.        |
| `ci:`       | Changes to CI configuration files and scripts.                         |
| `build:`    | Changes that affect the build system or external dependencies.         |

Check the `git log` output from step 4:

- If every commit subject already starts with the same `type:` or `type(scope):` prefix from the table above, reuse that type directly — branches are usually built one commit at a time via `create-git-commit`, so this is the common case.
- Otherwise (mixed types, or commits that don't follow the convention), infer the type from the full diff content the same way `create-git-commit` does: pick the prefix that best matches what the diff actually does, not what any individual commit message says.

Follow the selected reference's title and description conventions. Preserve explicit user wording and use existing PR details as defaults in update mode. Repository instructions and templates take precedence over provider defaults. Do not invoke `summarize-pr` for GitHub; that skill remains Azure-specific.

**Risk assessment.** Read [risk-assessment.md](references/risk-assessment.md) and score the diff from step 4 with it. Put the marked `Risk Assessment` block into the drafted description at the placement the selected provider reference and that file describe. This applies to both providers and to update mode, where the block is regenerated for the current `HEAD`. The score is advisory and never blocks publishing.

Collect any missing target, title, description, draft preference, and reviewers with `ask_user`. Default new PRs to ready for review with no reviewers; preserve existing draft state and reviewers unless the user requests a change. Azure DevOps alone includes the optional ClickUp URL. If the target changes, repeat step 4 and redraft against the corrected target.

### 6. Preview and publish

Show the full concrete preview: provider and repository, source → target, title, draft state, reviewer changes, and complete description. Obtain **Create PR** / **Update PR** / **Abort** authorization unless the session already authorizes publishing these details.

Write the exact approved description to a temporary UTF-8 file, `PR_BODY_FILE`, preserving newlines and literal Markdown. Prefer a file-writing tool or a quoted heredoc. Use a shell-safe title variable instead of interpolating untrusted title text into a command.

```bash
git push -u "$PR_REMOTE" "$BRANCH"
```

If a normal push is rejected, inspect why; do not automatically force-push. Use `--force-with-lease` only when the user authorized rewriting the remote branch. Stop on push failure.

Create or update via the selected reference, then fetch the resulting PR to verify repository, source/target, title, description, and draft state. If the CLI reports a failure or the result is ambiguous, re-query before retrying creation to avoid duplicates. Do not report success until verified. Remove the temporary body file when finished.

### 7. Report the result

For GitHub, report created/updated, PR number/title, source → target, and the returned URL. For Azure DevOps, first follow its optional ClickUp backlink/status flow, then include those outcomes in the result. Include the overall risk level and the number of unticked checklist items, which are the owner's to complete. Report partial failures accurately without undoing a successful PR operation. Mention any stash or local fixes committed during the workflow.
