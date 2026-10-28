---
name: sync-work-notes
description: 'Sync the private work-notes repository: pull first, record what this session decided or finished (decisions, reports, agent memory) following the notes README, check for secrets, then commit and push. Also pulls at the start of work. Use when: sync work notes, update work notes, end of day, 下班, 更新 work notes, 同步筆記.'
---

# Sync Work Notes

The work notes are a private Git repository that `install.sh` clones and links (see the dotfiles README, "Work notes"). The user invoking this skill authorizes one commit and one push of the notes; it does not authorize any other outward action.

Follow the dotfiles credential policy throughout. Never print the notes remote URL: keep Git network commands quiet and report only success or failure.

## 1. Locate and pull

```bash
source "$(command -v local-env)" WORK_NOTES_DIR
NOTES_DIR="${WORK_NOTES_DIR:-$HOME/work-notes}"
git -C "$NOTES_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || echo "missing"
git -C "$NOTES_DIR" status --short
BEFORE="$(git -C "$NOTES_DIR" rev-parse HEAD)"
if git -C "$NOTES_DIR" pull --rebase --autostash --quiet >/dev/null 2>&1; then echo "pulled"; else echo "pull failed"; fi
```

- Missing: tell the user to set `WORK_NOTES_REPO` in `alias/.env` and run `install.sh`; stop.
- Pull failed: show `git -C "$NOTES_DIR" status --short` and stop. Do not resolve conflicts in notes without asking, and never force-push.
- Start-of-work request (only pulling): report `git -C "$NOTES_DIR" log --oneline "$BEFORE"..HEAD` when the pull brought commits (run it in the same shell as the pull), then stop.

## 2. Update the notes

Read `$NOTES_DIR/README.md` first; its rules and layout override anything here. Then record only facts from this session or from tools you checked in it:

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

## 4. Commit and push

```bash
git -C "$NOTES_DIR" commit -q -m "<short English summary of what changed>"
if git -C "$NOTES_DIR" push --quiet >/dev/null 2>&1; then echo "push ok"; else echo "push failed"; fi
```

No AI attribution or co-author trailers. If nothing changed, say so and skip the commit. If the push fails, leave the commit in place and report it; `doctor` will show it as unpushed.

## 5. Report

One short list: files changed with a phrase each, the commit hash, and whether the push succeeded.
