# Azure DevOps merge operations

Use the installed `ado-rest` command for every request; run `ado-rest context` first and use its `repository` as `REPO`. Never print tokens or remote URLs.

## Readiness

```bash
ado-rest GET "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}?api-version=7.1" > "$PR_JSON_FILE"
jq '{status, isDraft, mergeStatus, title, head: .lastMergeSourceCommit.commitId, merge: .lastMergeCommit.commitId, votes: [.reviewers[]? | {n: .displayName, v: .vote}]}' "$PR_JSON_FILE"
ado-rest GET "/_apis/build/builds?branchName=refs/pull/${PR_ID}/merge&\$top=4&queryOrder=queueTimeDescending&api-version=7.1" \
  | jq -r '.value[] | "\(.id) \(.definition.name) \(.status) \(.result // "-") \(.sourceVersion[0:8])"'
```

The checklist is read from `description` in `$PR_JSON_FILE` as described in the shared procedure. Ready means `status` `active`, not draft, `mergeStatus` `succeeded`, required approvals (vote 10 or 5), and the newest build of every pipeline succeeded with `sourceVersion` equal to the PR's `lastMergeCommit`.

## Merge

```bash
BODY=$(python3 -I -c '
import json, re, sys
d = json.loads(open(sys.argv[1]).read(), strict=False)
desc = re.sub(r"<!-- risk-assessment:start -->.*?<!-- risk-assessment:end -->", "", d.get("description") or "", flags=re.S)
msg = d["title"] + "\n\n" + desc.strip()
print(json.dumps({"status": "completed",
  "lastMergeSourceCommit": {"commitId": d["lastMergeSourceCommit"]["commitId"]},
  "completionOptions": {"mergeStrategy": "squash", "deleteSourceBranch": True,
    "transitionWorkItems": True, "mergeCommitMessage": msg}}, ensure_ascii=False))
' "$PR_JSON_FILE")
ado-rest PATCH "/_apis/git/repositories/${REPO}/pullrequests/${PR_ID}?api-version=7.1" "$BODY"
```

`lastMergeSourceCommit` pins the verified head. Poll the PR until `status` is `completed` and record `lastMergeCommit`. A response of `active` with no error usually means completion is queued; re-query before retrying.

## Known failures

- **HTTP 400**: the merge message is too long (about 4000 characters). Drop verbose sections such as test reports from the description copy and retry.
- **HTTP 403**: a blocking policy is not satisfied, commonly a build policy that expired after the target moved. Read the evaluations with an encoded artifact ID (`ado-rest` rejects raw `:` and `///`); take the project ID from any build's `.project.id`:

  ```bash
  AID=$(python3 -I -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' \
    "vstfs:///CodeReview/CodeReviewId/${PROJECT_ID}/${PR_ID}")
  ado-rest GET "/_apis/policy/evaluations?artifactId=${AID}&api-version=7.1-preview.1" \
    | jq -r '.value[] | "\(.evaluationId) \(.configuration.type.displayName) \(.status) expired=\(.context.isExpired // "-")"'
  ado-rest PATCH "/_apis/policy/evaluations/${EVALUATION_ID}?api-version=7.1-preview.1" '{}'
  ```

  Requeue each expired build evaluation, wait for the new builds to succeed on the new merge commit, then merge again. Other rejected policies need the user.

Build step logs, when needed, come from `/_apis/build/builds/<id>/logs/<logId>?api-version=7.1&$format=json` (`.value[]` holds the lines).

## ClickUp close-out

Only when the PR description links exactly one ClickUp task and the token loads with `source "$(command -v local-env)" CLICKUP_API_TOKEN` (never export or print it): fetch the task, read its list's statuses, and set the done/complete status the user uses (`ask_user` if several fit). Otherwise skip and report why. The source branch is deleted by `deleteSourceBranch`.
