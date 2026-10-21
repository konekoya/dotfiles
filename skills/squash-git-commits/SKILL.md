---
name: squash-git-commits
description: 'Squash a feature branch into one commit relative to its target branch. Discover the target, show a before/after preview, and propose a commit subject before rewriting history.'
argument-hint: '<optional commit subject>'
---

# Git Squash

## When to Use

When you want to collapse all commits on the current feature/fix branch into a single, clean commit before merging.

## Procedure

### 1. Detect the squash range

Resolve the target from an existing PR, the user's instruction, or the repository's documented convention. Otherwise inspect `origin/HEAD`; if unavailable, use the sole existing primary branch among `origin/main`, `origin/master`, and `origin/develop`, or ask the user to choose. Prefer the remote-tracking target ref over a stale local copy, and verify it exists. Do not squash a primary/default branch or detached HEAD.

Find where the current branch diverged from the selected target:

```bash
MERGE_BASE=$(git merge-base "$BASE_REF" HEAD) || exit 1
```

Count the commits to squash:

```bash
COMMIT_COUNT=$(git rev-list --count "$MERGE_BASE"..HEAD)
```

- If `COMMIT_COUNT` is **0 or 1**, stop — there is nothing to squash. Tell the user.
- If the working tree is dirty (`git status --porcelain` is non-empty), stop and ask the user to commit or stash first.

### 2. Collect commit messages

Gather all subjects in the range (oldest → newest):

```bash
git log --reverse --format='%h %s' "$MERGE_BASE"..HEAD
```

Save this output — it is needed for the preview and for generating the summary.

### 3. Generate the commit subject (if not provided)

If the user supplied a commit subject, use it as-is.

Otherwise, read every commit message in the range and write **one** conventional-commit subject line that summarises the overall change:

- Use the correct type prefix (`feat:`, `fix:`, `chore:`, `refactor:`, etc.).
- Keep the subject **≤ 72 characters**.
- Do **not** include the original messages in the commit body.

### 4. Show before / after preview and ask for approval

Present a clear comparison so the user can verify:

```
📋 Squash preview
─────────────────

BEFORE (N commits on <branch>):
  abc1234 fix: typo in login page
  def5678 feat: add login form
  ghi9012 chore: scaffold login page

AFTER (1 commit):
  <staged> feat: add login page with form and validation

─────────────────
```

Use `ask_user` to get explicit approval:

> "Proceed with squash? This rewrites history and cannot be undone easily."

Choices: **Yes, squash** / **No, abort**

If the user declines, stop immediately — do not modify any commits.

### 5. Perform the squash

```bash
git reset --soft "$MERGE_BASE"
git commit -m "<subject>"
```

### 6. Show result

Display the new commit:

```bash
git log --oneline -1
```

Remind the user:

> If this branch was already pushed, you will need `git push --force-with-lease` to update the remote.
