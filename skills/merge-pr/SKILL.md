---
name: merge-pr
description: 'Merge one or more ready GitHub or Azure DevOps PRs in a safe order: verify approvals and required checks on the current head, check cross-PR conflicts, refresh stale checks, squash-merge, then close out the linked ClickUp task (Azure DevOps) and the local worktree. Use when: merge PR, complete PR, 合併 PR.'
---

# Merge Pull Requests

Use the host's question tool wherever this says `ask_user`. Merging is outward-facing: merge only PRs the user named or approved in this session, and never bypass branch protection or policies (no `--admin`, no policy bypass) unless the user explicitly asks for that specific PR.

## Provider routing

Use the repository's `azure-devops.remote` setting, otherwise `origin`, as `PR_REMOTE`. Inspect its URL in memory and never print it, since it could contain credentials:

```bash
PR_REMOTE=$(git config --local --get azure-devops.remote || printf '%s' origin)
```

| Remote host | Provider reference |
| --- | --- |
| `github.com` | [GitHub](references/github.md) |
| `dev.azure.com`, `ssh.dev.azure.com`, or `*.visualstudio.com` | [Azure DevOps](references/azure-devops.md) |

Read only the selected reference. If the remote is missing or another provider, stop and tell the user this skill does not cover it.

## 1. Check readiness

For each candidate PR, use the reference's readiness query. A PR is ready only when it is open, not a draft, has no merge conflict, has the required approvals, and every required check **succeeded on the PR's current head (or current merge commit)**. A green result from an older commit does not count. Report each PR that is not ready, with the reason, and do not merge it.

## 2. Choose an order

With several ready PRs against the same target, fetch the target and branches, list overlapping files, and chain `git merge-tree --write-tree` to confirm each PR still merges after the previous ones:

```bash
git diff --name-only "origin/$TARGET...origin/$BRANCH"
TREE=$(git merge-tree --write-tree "$BASE" "origin/$BRANCH") || echo "conflict"
BASE=$(git commit-tree "${TREE%%$'\n'*}" -p "$BASE" -m simulated)
```

Merge small, independent PRs first and the PR with the widest shared-file footprint last. Stop and report on any conflict. After each merge, the remaining PRs' checks may become stale; re-run step 1 for the next PR before merging it.

## 3. Merge

Squash-merge unless the repository requires another strategy. Pin the merge to the head you verified so a late push cannot slip in. Use the PR title as the subject and its description as the body, trimmed if the provider rejects the length. Never add AI attribution or co-author trailers. Follow the reference for the command, stale-check refresh, and known failures. Verify the PR reports merged/completed and record the merge commit before moving on.

## 4. Close out

- **Linked task**: follow the reference (Azure DevOps updates an existing ClickUp task; GitHub skips ClickUp).
- **Worktree and branches**: if the merged branch is checked out in a local worktree, remove the worktree only when its tree is clean and its `HEAD` equals the merged PR head. Use the managing tool's remove command when one exists (for example `orca worktree rm`); otherwise `git worktree remove`. Never force-remove. Delete the local branch only after its worktree is gone.

Report each PR as merged (merge commit), skipped (reason), or blocked (failing requirement), plus the task and worktree outcomes.
