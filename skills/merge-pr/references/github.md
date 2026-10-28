# GitHub merge operations

Use the GitHub CLI (`gh`); Azure tooling and ClickUp are unnecessary. Check `gh auth status --active --hostname github.com`; on failure suggest `gh auth login --hostname github.com` and never print tokens. Parse `GH_REPO` as `OWNER/REPO` from the selected remote and pass `--repo "$GH_REPO"` to every command.

## Readiness

```bash
gh pr view "$PR_ID" --repo "$GH_REPO" \
  --json number,title,state,isDraft,baseRefName,headRefName,headRefOid,isCrossRepository,mergeable,mergeStateStatus,reviewDecision
gh pr checks "$PR_ID" --repo "$GH_REPO" --required --json name,state,bucket
```

`gh pr checks` exits non-zero with `no checks reported` when the branch has no checks; treat that as no required checks, not as a failure.

Ready means `state` `OPEN`, not draft, `mergeable` `MERGEABLE`, `reviewDecision` `APPROVED` (or empty when no review is required), and every required check in bucket `pass`. Read `mergeStateStatus`:

- `CLEAN` or `HAS_HOOKS`: mergeable now.
- `BEHIND`: branch protection requires the branch to be up to date. With the user's approval, run `gh pr update-branch "$PR_ID" --repo "$GH_REPO"`, wait for the required checks on the new head, then re-check.
- `BLOCKED`: a review, check, or rule is missing; report which.
- `DIRTY`: merge conflict; stop.
- `UNSTABLE`: only non-required checks fail; report them and ask before merging.
- `UNKNOWN`: GitHub is still computing; query again.

## Merge

Use the PR title as the subject and its body as the merge body, and pin the verified head:

```bash
gh pr merge "$PR_ID" --repo "$GH_REPO" --squash \
  --match-head-commit "$HEAD_SHA" --subject "$PR_TITLE (#$PR_ID)" --body-file "$MERGE_BODY_FILE"
```

- Add `--delete-branch` only when the head branch is not checked out in any local worktree and the PR is not from a fork; otherwise delete the remote branch after close-out with `git push "$PR_REMOTE" --delete "$BRANCH"` (same-repository branches only).
- If the repository uses a merge queue or auto-merge is required, `gh pr merge --auto` enqueues instead of merging; report that it is queued and re-check later rather than claiming it merged.
- A head-mismatch error means someone pushed after verification; re-run readiness instead of retrying blindly.
- If squash merging is disabled, ask which allowed strategy to use.

Confirm with `gh pr view "$PR_ID" --repo "$GH_REPO" --json state,mergedAt,mergeCommit` that `state` is `MERGED` and record `mergeCommit.oid`.

## Close-out

No ClickUp or other task tracking. If the PR body uses a closing keyword for a GitHub issue, GitHub closes it on merge; just report it.
