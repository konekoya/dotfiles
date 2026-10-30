# GitHub PR Operations

Read this reference only for GitHub remotes. Use the GitHub CLI (`gh`); Azure tooling and ClickUp are unnecessary.

## Authentication and repository context

Parse `GH_REPO` as `OWNER/REPO` from the selected remote, stripping an optional `.git` suffix. Pass `--repo "$GH_REPO"` to every PR command; `gh repo view` takes the repository as a positional argument.

```bash
gh auth status --active --hostname github.com
```

If `gh` is missing, suggest `brew install gh`. If authentication fails, stop and suggest `gh auth login --hostname github.com`; never print tokens. A configured `GH_TOKEN` or `GITHUB_TOKEN` can also authenticate `gh`.

For an ordinary repository, `GH_REPO` is both the source and base repository, `BASE_REMOTE="$PR_REMOTE"`, and `GH_HEAD="$BRANCH"`. For a fork, inspect `origin` and `upstream` and honor the user's intended base: use the base repository for `GH_REPO` and its remote for `BASE_REMOTE`, push only to the selected source remote, and use `GH_HEAD="<source-owner>:$BRANCH"` when creating the PR. Do not create a fork automatically. If no usable base remote exists, obtain its target ref before inspecting the diff. If `gh` cannot address a particular fork (such as an organization-owned head), explain the limitation instead of publishing to another repository.

## Existing PR and default branch

```bash
gh pr list --repo "$GH_REPO" --head "$BRANCH" --state open --limit 100 \
  --json number,url,title,body,baseRefName,headRefName,headRepository,headRepositoryOwner,isDraft,reviewRequests
```

The list command's `--head` takes the branch alone, not `owner:branch`. Filter its results by `headRepositoryOwner` and `headRepository` to match the actual source repository, especially for forks; branch names alone can collide. Select a PR only after matching the source owner/repository and branch. Stop on lookup errors and ask if multiple PRs match. Preserve the returned number as `PR_ID`, URL as `PR_URL`, and existing details as defaults.

When the base remote's default branch is unavailable locally:

```bash
gh repo view "$GH_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name'
```

## Draft title and description

- Use the repository's title convention; otherwise draft `<type>: <description>` using the shared Conventional Commit type. Preserve an explicit title or existing PR title unless it violates repository requirements. Do not extract a ClickUp ID from a branch or add a task bracket.
- Inspect repository PR templates (`.github/PULL_REQUEST_TEMPLATE.md`, `.github/pull_request_template.md`, root or `docs/` variants, and template directories) and contributor instructions before drafting. Preserve the selected template's structure; ask when multiple templates apply and no choice is evident.
- Follow the user/repository language; otherwise use English. With no template, use a concise `## Summary` and `## Testing`, describing the purpose, main changes, and checks actually run. Include material validation gaps. Include review history only when relevant and supported by evidence.
- No ClickUp field, title lookup, `Closes <ClickUp URL>` line, task creation, backlink, or status offer. Link a GitHub issue when explicitly supplied/requested; use a closing keyword only when the change resolves that issue.
- Add the marked `## Risk Assessment` block from [risk-assessment.md](risk-assessment.md), including its PR checklist, as the last thing in the body; with a PR template, append it after the template's last section and leave the template itself untouched.
- In update mode, preserve useful existing body content, issue links, and template sections. Refresh stale facts from the diff rather than blindly replacing the body.

## Publish

Create after the approved push:

```bash
gh pr create --repo "$GH_REPO" --head "$GH_HEAD" --base "$TARGET_BRANCH" \
  --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
```

Add `--draft` for a draft and repeat `--reviewer <login-or-team>` only for requested reviewers. Use GitHub logins or `org/team` handles rather than Azure email addresses. Explicit `--head` avoids the CLI's automatic push/fork prompts. Capture the returned URL and query the PR for its number.

Update the selected PR:

```bash
gh pr edit "$PR_ID" --repo "$GH_REPO" \
  --title "$PR_TITLE" --body-file "$PR_BODY_FILE"
```

Add `--base "$TARGET_BRANCH"` only for a requested target change. Use `--add-reviewer` for requested additions and `--remove-reviewer` only for explicit removals; do not clear existing requests by default.

`gh pr edit` has no draft flag. Only for an authorized draft-state change, use:

```bash
# Ready for review → draft
gh pr ready "$PR_ID" --repo "$GH_REPO" --undo
# Draft → ready for review
gh pr ready "$PR_ID" --repo "$GH_REPO"
```

Run only the applicable transition. Verify the final result:

```bash
gh pr view "$PR_ID" --repo "$GH_REPO" \
  --json number,url,title,body,baseRefName,headRefName,headRepository,headRepositoryOwner,isDraft,reviewRequests
```

Compare it with the approved preview and return the URL supplied by GitHub. On a failed metadata or draft update, report which parts succeeded; do not create a second PR to compensate.

CLI references: [create](https://cli.github.com/manual/gh_pr_create), [edit](https://cli.github.com/manual/gh_pr_edit), [list](https://cli.github.com/manual/gh_pr_list), [ready](https://cli.github.com/manual/gh_pr_ready).
