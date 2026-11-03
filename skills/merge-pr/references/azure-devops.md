# Azure DevOps merge operations

Use the installed `pr merge` command for readiness and for the merge itself. It resolves the repository and profile from the selected remote (check with `ado-rest context`), sends no token or URL to its output, and never bypasses policy. Do not rebuild its requests with `ado-rest`, `az repos` or curl. Never print tokens or remote URLs.

## Readiness

```bash
pr merge "$PR_ID"           # read-only preview: sends no write request
pr merge "$PR_ID" --json    # same verdict as one JSON object
```

The preview prints a verdict (`ready` or `blocked`) and one `❌ <code>: <message>` line per block reason. It covers an active, non-draft PR, no merge conflict, the required approvals, every required policy and build succeeded on the PR's **current** merge commit (a green build on an older commit is `build_stale`), and the manual test checklist read from the `risk-assessment` block (markers and boxes only). Anything the API reports that the command does not recognise is `unknown_policy_state`, never ready. Report each blocked PR with its reason lines and do not merge it. When the checklist is not clean, also report its state to the user as the shared procedure requires; the preview prints the unticked items, the overall rating and the `Rollback` line.

Block codes: `not_active`, `draft`, `conflict`, `merge_status`, `approval_rejected`, `approval_missing`, `policy_not_approved`, `build_expired`, `build_pending`, `build_failed`, `build_stale`, `build_missing`, `checklist_unticked`, `checklist_stale`, `checklist_unreadable`, `message_attribution`, `unknown_policy_state`, and (from `--execute`) `head_mismatch`.

## Merge

Only after the user approved this PR in this session, and only with the head the preview showed:

```bash
pr merge "$PR_ID" --execute --head "$HEAD_SHA"
```

The command re-verifies everything itself, refuses on any block reason or when the head moved, then squash-merges pinned to the verified head with the PR title as subject and the description (without the `risk-assessment` block) as body, deletes the source branch, and polls until the PR is `completed`. It prints the merge commit; record it. A `timeout` or `failed` result is not a merge: check the PR (`pr merge "$PR_ID"`, `pr status`) before retrying, never retry blindly. `--json` returns the same result as one object (`result`: `completed`, `refused`, `timeout`, `abandoned` or `failed`).

### Waiving the checklist

`--waive-checklist` lets `--execute` proceed past `checklist_unticked` and `checklist_stale` only. Use it only when the owner has said so for that specific PR in this session; record the waiver in the final report. It never ticks or edits a box, and it does not clear any other reason. Never add it on your own initiative.

## Expired builds

Required builds can expire when the target branch moves (`build_expired`). Requeue them explicitly, then wait for the new builds and preview again:

```bash
pr merge "$PR_ID" --requeue-expired     # requeues expired Build evaluations only, then previews
pr status "$PR_ID" --watch              # wait for the builds
```

`--requeue-expired` cannot be combined with `--execute`, and other rejected policies are only reported. Do this after each preceding merge before attempting the next PR. A build that failed needs its test fixed in the PR's branch: read the failing test name and message from `pr status "$PR_ID"`, fix it, push normally, and wait again.

## Known failures

- **Message too long** (the PATCH returns HTTP 400): the command says so. Shorten the description's verbose sections (such as test reports) and re-run the preview, then `--execute`.
- **Policy not satisfied** (HTTP 403): a build policy usually expired after the target moved. Re-run the preview and follow the reported reason.

## ClickUp close-out

Only when the PR description links exactly one ClickUp task and the token loads with `source "$(command -v local-env)" CLICKUP_API_TOKEN` (never export or print it): fetch the task, read its list's statuses, and set the done/complete status the user uses (`ask_user` if several fit). Otherwise skip and report why. The source branch is deleted by the merge.
