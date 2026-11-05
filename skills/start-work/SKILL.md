---
name: start-work
description: 'Start a work session by pulling the private work notes on main, reading the notes and project guides, and reporting board and tracker status. Use when: start work, begin work, check project status, 開始工作, 開工, 早安, 查看專案狀態.'
---

# Start Work

The work notes are a private Git repository that `install.sh` clones and links (see the dotfiles README, "Work notes"). Follow the notes README and the current project's guide for the board, tracker, and routing rules. The skill is read-only except for the authorized notes pull: invoking it authorizes that pull on `main` only. Never edit notes, change tracker data, or make any other Git change. Never print the notes remote URL; keep Git network output quiet and report only safe summaries.

## 1. Locate and synchronize the notes

```bash
source "$(command -v local-env)" WORK_NOTES_DIR
NOTES_DIR="${WORK_NOTES_DIR:-$HOME/work-notes}"
if ! git -C "$NOTES_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "missing"
  exit 0
fi
git -C "$NOTES_DIR" status --short
BRANCH="$(git -C "$NOTES_DIR" branch --show-current)"
if [ "$BRANCH" = "main" ]; then
  BEFORE="$(git -C "$NOTES_DIR" rev-parse HEAD)"
  if git -C "$NOTES_DIR" pull --rebase --autostash --quiet >/dev/null 2>&1; then
    echo "pulled"
    git -C "$NOTES_DIR" log --oneline "$BEFORE"..HEAD
  else
    echo "pull failed"
    git -C "$NOTES_DIR" status --short
  fi
else
  if git -C "$NOTES_DIR" rev-parse --verify origin/main >/dev/null 2>&1; then
    echo "on branch $BRANCH; origin/main commits not in it: $(git -C "$NOTES_DIR" rev-list --count HEAD..origin/main)"
  else
    echo "on branch $BRANCH; origin/main is not available locally, so its missing commit count is unknown"
  fi
fi
```

- Missing: tell the user to set `WORK_NOTES_REPO` in `alias/.env` and run `install.sh`; stop.
- On `main`: the pull is the only authorized write. If it fails, show `git -C "$NOTES_DIR" status --short` and stop. Do not resolve conflicts without asking; never force-push.
- On another branch: do not pull, fetch, switch branches, rebase, or otherwise change Git state. Report the count against the locally available `origin/main` ref; if it is unavailable, say the count could not be determined. Ask before taking any further action.

## 2. Read the notes and project guidance

Read `$NOTES_DIR/README.md` first. Then follow its instructions to read the board or status file it defines. Read the README's agent-instructions section, the current project's guide, and any routing or delegation guides those documents link. These files define the project's repository, tracker settings, list identifiers, iteration, and status/type filters. Keep project-specific values out of this skill and do not guess missing values.

If the notes repository is missing, or the pull on `main` fails, stop without querying the board or tracker. If the project has no tracker, say that the tracker step was skipped and continue with the board summary.

## 3. Query the tracker as the project guide defines it

Use only the read commands and settings specified by the current project's guide. If the guide does not define a tracker, skip this step.

- **ClickUp:** Run `clickup open --list <list-id>` for each list named by the guide, adding `--assignee me` only when the guide calls for it. Run `clickup snapshot --since <date> --list <list-id>` for those lists. Use the last-session date recorded in the project guide or board; if none is recorded, use the date seven days ago and say that fallback was used in the report. Repeat `--list` for additional lists.
- **Azure DevOps:** Run `ado-tasks` from inside the project repository named by the guide, with `--iteration '<iteration path>'` taken from that guide. Pass `--state` and `--type` only when the guide names them. Do not use `--current` or guess an iteration. Check for the repository's Azure DevOps profile with `ado-rest context` while in that repository, suppressing its output; if the repository is unavailable or the check fails because no profile is configured, skip the query and report why. If the profile exists, run `ado-tasks` there. Do not include profile details in the report.

If a task's status looks wrong, list the task and ask the user. Never run `clickup status`, update a ClickUp task, or change a work item.

## 4. Check QA hand-offs (read-only)

Apply this step only when the project guide defines a QA hand-off rule. If it defines none, skip the step silently and leave it out of the report. Otherwise, when syncing tasks, run only the read-only query the guide specifies for the rule and list the user's items that are already in the guide's waiting-for-QA state but still assigned to the user. Tell the user which ones (ID and title). Do not build the query yourself, and never reassign an item, change a state, or comment; the guide says who confirms the hand-off and when. If the query cannot run, say why and continue.

## 5. Report

Summarize the board or status file, tracker findings (or why the query was skipped), the QA hand-off items from step 4 when the guide defines the rule, and the iteration used with its source stated as "from the notes." If no iteration was defined, say so and skip the Azure DevOps query. For ClickUp snapshots, state the date used and whether it came from the guide/board or the seven-day fallback. Include the notes pull result and the commit summaries it brought, or the non-main branch's missing `origin/main` count. Do not include the notes remote URL. Make no notes, tracker, or Git changes beyond the authorized pull on `main`.
