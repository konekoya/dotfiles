# Azure DevOps

Use `ado-rest context` to inspect the selected repository context and `ado-rest GET` for supported reads. `ado-rest` also supports write methods; execute them only when the user has authorized the specific action. See the [command reference](../../README.md#ado-rest) and [profile setup](../../README.md#azure-devops-work-and-personal-accounts).

Profiles are selected per repository and bound to an organization. The selected fetch and push remotes must identify the same repository; a profile/organization mismatch fails closed. Do not redirect a repository with an environment override or switch Azure accounts to make a request work. Consult the [create-pr](../../skills/create-pr/SKILL.md) and [merge-pr](../../skills/merge-pr/SKILL.md) skills for their workflows.

Use `pr list`, `pr status [ID] [--watch] [--interval SECONDS] [--json]`,
`pr comments [ID]`, `pr merge [ID]`, and `pr open` for PR operations. See the [pr
command reference](../../README.md#pr) for details.

`pr merge [ID] [--json]` is a read-only preview of whether a PR can be squash-merged. Writes
need the owner's approval of that PR in this session: `pr merge ID --execute --head SHA` merges
(pinned to the previewed head, never bypassing policy), `--waive-checklist` is the owner's
decision to merge past unticked or stale checklist items, and `pr merge ID --requeue-expired`
requeues expired build evaluations only. It does not support GitHub remotes.

## Write calls

`ado-rest --help` prints the usage with a write example; every body error repeats it.
`POST`, `PATCH`, and `PUT` need a JSON body, `DELETE` may omit it, and `GET` takes none.
Pass the body as the third argument, `-` to read it from stdin, or `@FILE` to read it
from a file. Build the JSON with `jq -n` instead of quoting it by hand.

```sh
# Add a comment to an existing pull request thread.
body="$(jq -n --arg text 'Thanks, fixed.' '{content: $text, commentType: "text"}')"
ado-rest POST '/_apis/git/repositories/<repository>/pullrequests/<id>/threads/<thread>/comments?api-version=7.1' "$body"

# Start a new thread; the body can come from stdin.
jq -n --arg text 'Please check this.' \
  '{comments: [{parentCommentId: 0, content: $text, commentType: "text"}], status: "active"}' |
  ado-rest POST '/_apis/git/repositories/<repository>/pullrequests/<id>/threads?api-version=7.1' -
```

Do not pipe the output into `jq` with `2>&1`: error text is not JSON and hides the real
message. Keep stderr separate when filtering a response.
