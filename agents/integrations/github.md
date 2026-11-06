# GitHub

Use `gh-auth --check` to classify authentication availability and `gh-auth <gh arguments>` for GitHub CLI operations. The wrapper loads a configured token for that process or falls back to the existing GitHub CLI login; it does not print the token. See the [gh-auth reference](../../README.md#gh-auth). GitHub operations use this wrapper, not the Azure DevOps API or `ado-rest`.

The [create-pr skill](../../skills/create-pr/SKILL.md) supports GitHub without ClickUp coupling. Check the user's authorization before creating or changing remote resources.

For pull requests, `pr list`, `pr status [ID] [--watch] [--interval SECONDS] [--json]`,
and `pr open` support GitHub remotes. List/status use the validated selected remote
and pass its owner/repository explicitly through `gh-auth`; no Azure profile is needed.
List groups open PRs authored by you and awaiting your review. List queries fail at
1000 results rather than silently truncate. Status resolves exactly one open PR for
the named branch in the selected source repository; for fork PRs hosted elsewhere,
select the base repository and pass an ID. It never guesses an upstream.

Status JSON keeps the shared allowlist; organization is the owner, project and every
buildId are null. Empty or explicitly null check rollups mean none, while unknown
check states remain conservative. Watch refreshes head/check/review metadata each
iteration. CI status is not merge readiness. `pr comments` and `pr merge` remain
unsupported for GitHub. See the [pr command reference](../../README.md#pr).
