---
name: create-git-commit
description: 'Create a git commit for staged or unstaged changes following Conventional Commits. Generates a commit title from the diff, asks the user to approve or revise it, then commits. Use when: commit changes, make a commit, 提交, git commit.'
argument-hint: '<optional commit title>'
---

# Create Git Commit

## When to Use

When you want to commit the current changes with a well-formed Conventional Commit message. Inspects the diff, proposes a title, asks the user for approval, then creates the commit.

## Conventional Commit Types

Always pick the most accurate prefix:

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

## Procedure

### 1. Pre-flight checks

Check that there is something to commit:

```bash
git status --porcelain
```

- If the output is empty, stop — there is nothing to commit. Tell the user.
- If there are only untracked files the user has not staged, ask whether to include them before staging anything.

### 2. Review the changes

Inspect what will be committed so the title and body are accurate:

```bash
git status
git diff --staged
git diff
```

- If nothing is staged but there are unstaged changes, ask the user whether to stage everything (`git add -A`) or only specific files.
- Never blindly `git add -A` if files like `.env`, credentials, or build artifacts appear in the diff. Warn the user first.

### 3. Generate the commit title

If the user supplied a title as the argument, use it as-is (but still verify the type prefix is one of the table above; correct it if not).

Otherwise, write **one** Conventional Commit subject line that summarises the change:

- Pick the correct type prefix from the table above based on what the diff actually does.
- Keep the subject **≤ 72 characters**.
- Use the imperative mood ("add", "fix", "remove" — not "added", "fixes").
- Do **not** end with a period.
- If the change is scoped to a clear area, optionally use `type(scope): subject` (e.g., `feat(auth): add Google login`).

### 4. Show preview and ask for approval

**Always propose a title — never ask the user to write one from scratch.** Even if they invoked the skill without an argument, generate one from the diff (step 3) and present it as a concrete suggestion.

Present the proposed commit so the user can verify:

```
📋 Commit preview
─────────────────

Files to commit:
  M  alias/.git_alias
  A  scripts/new-thing

Proposed title:
  feat: add new-thing script for bulk renames

─────────────────
```

Use `ask_user` with the suggestion as the first / recommended option:

> "Use this commit title?"

Choices:
- **Use suggested title** (Recommended) — commits with the proposed title as-is.
- **Tweak the suggestion** — re-show the suggested title pre-filled so the user can edit it, then re-show the preview before committing.
- **Abort** — stop immediately; do not stage or commit anything new.

The user can always pick "Other" on the prompt to type a fully custom title, but the default path is approve-the-suggestion.

### 5. Create the commit

Stage the agreed files (if not already staged), then commit. Pass the message via a HEREDOC to preserve formatting:

```bash
git commit -m "$(cat <<'EOF'
<approved title>
EOF
)"
```

- Never use `--no-verify` unless the user explicitly asks. If a pre-commit hook fails, fix the underlying issue and create a **new** commit (do not `--amend`).

### 6. Show result

Display the new commit so the user can confirm:

```bash
git log --oneline -1
git status
```
