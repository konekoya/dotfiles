---
name: sync-work-notes
description: 'Sync the private work-notes repository: pull first, record what this session decided or finished (decisions, reports, agent memory) following the notes README, check for secrets, then commit on a notes branch, push it, and open a pull request for the user to review. Also pulls at the start of work. Use when: sync work notes, update work notes, end of day, 下班, 更新 work notes, 同步筆記.'
---

# Sync Work Notes

The work notes are a private Git repository that `install.sh` clones and links (see the dotfiles README, "Work notes"). Notes reach `main` only through a pull request that the user reviews and merges. The user invoking this skill authorizes one commit, one push of a notes branch, and opening (or updating) one pull request; it never authorizes pushing to `main` or merging, and it does not authorize any other outward action.

Follow the dotfiles credential policy throughout. Never print the notes remote URL: keep Git network commands quiet and report only success or failure.

## 1. Locate and pull

```bash
source "$(command -v local-env)" WORK_NOTES_DIR
NOTES_DIR="${WORK_NOTES_DIR:-$HOME/work-notes}"
git -C "$NOTES_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || echo "missing"
git -C "$NOTES_DIR" status --short
BRANCH="$(git -C "$NOTES_DIR" branch --show-current)"
BEFORE="$(git -C "$NOTES_DIR" rev-parse HEAD)"
git -C "$NOTES_DIR" fetch --quiet origin >/dev/null 2>&1 || echo "fetch failed"
if [ "$BRANCH" = "main" ]; then
  if git -C "$NOTES_DIR" pull --rebase --autostash --quiet >/dev/null 2>&1; then echo "pulled"; else echo "pull failed"; fi
else
  echo "on branch $BRANCH; origin/main commits not in it: $(git -C "$NOTES_DIR" rev-list --count HEAD..origin/main)"
fi
```

- On a notes branch: keep working on it (its PR is still open or not yet created). If `origin/main` has commits the branch lacks, tell the user and ask before rebasing; check with `gh pr list --head "$BRANCH" --state all` whether its PR was already merged, and if so ask whether to start a fresh branch from `origin/main`.

- Missing: tell the user to set `WORK_NOTES_REPO` in `alias/.env` and run `install.sh`; stop.
- Pull failed: show `git -C "$NOTES_DIR" status --short` and stop. Do not resolve conflicts in notes without asking, and never force-push.
- Start-of-work request (only pulling): report `git -C "$NOTES_DIR" log --oneline "$BEFORE"..HEAD` when the pull brought commits (run it in the same shell as the pull), read the board or status file if the README defines one, then stop.

## 2. Update the notes

Read `$NOTES_DIR/README.md` first; its rules and layout override anything here. Then record only facts from this session or from tools you checked in it:

- Handoff state, if the README defines a board or status file: rewrite it to the current unfinished work, who is on it, what it waits for, and next steps.
- Decisions agreed with other people or teams, with date and references (task IDs, PR numbers).
- Progress for the current report period (merged or opened PRs, task status changes).
- Memory: if your tool keeps its memory inside the notes (for Claude Code, a symlinked project memory directory), it is already there; update or add entries per your memory rules for preferences, corrections, and reusable procedures learned this session. Other tools skip this.

Keep entries short and in your own words: no raw logs, API responses, or pasted messages. Do not rewrite unrelated entries.

## 3. Check before committing

```bash
git -C "$NOTES_DIR" add -A
git -C "$NOTES_DIR" diff --cached --stat
git -C "$NOTES_DIR" diff --cached -U0 | grep -nE '(ghp_|github_pat_|pk_[A-Za-z0-9]{8,}|xox[bp]-|AKIA[0-9A-Z]{12}|-----BEGIN [A-Z ]*PRIVATE KEY|Authorization:|[A-Za-z]+://[^/ ]+:[^@/ ]+@)' | cut -d: -f1 | sort -u
```

The last command prints only diff line numbers. If it prints anything, unstage (`git -C "$NOTES_DIR" reset -q`), tell the user which file looks sensitive without quoting it, and stop. Also confirm `links.local.tsv` is not staged; it is machine-specific.

## 4. Commit on a branch, ask, push, open a PR

Never commit to `main`. If the current branch is `main`, create a branch first; uncommitted changes move with it:

```bash
[ "$(git -C "$NOTES_DIR" branch --show-current)" = "main" ] && git -C "$NOTES_DIR" switch -q -c "notes/$(date +%Y-%m-%d)-<short-slug>"
git -C "$NOTES_DIR" commit -q -m "<short English summary of what changed>"
```

Before pushing, list anything you are unsure about (where an entry belongs, wording, whether something is private, files changed by another session) and ask the user. Push only after they answer; never push on a guess.

```bash
if git -C "$NOTES_DIR" push --quiet -u origin HEAD >/dev/null 2>&1; then echo "push ok"; else echo "push failed"; fi
(cd "$NOTES_DIR" && gh pr view --json url -q .url 2>/dev/null || gh pr create --base main --fill)
```

`gh pr create --fill` uses the commit messages; give it `--title`/`--body` when the branch has several commits. Do not merge the PR, approve it, or enable auto-merge; the user reviews and merges it. No AI attribution or co-author trailers. If nothing changed, say so and skip the commit. If the push fails, leave the commit in place and report it; `doctor` will show it as unpushed.

## 5. Report

One short list: files changed with a phrase each, the branch and commit hash, whether the push succeeded, and the PR link.
