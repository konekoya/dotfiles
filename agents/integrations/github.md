# GitHub

Use `gh-auth --check` to classify authentication availability and `gh-auth <gh arguments>` for GitHub CLI operations. The wrapper loads a configured token for that process or falls back to the existing GitHub CLI login; it does not print the token. See the [gh-auth reference](../../README.md#gh-auth). GitHub operations use this wrapper, not the Azure DevOps API or `ado-rest`.

The [create-pr skill](../../skills/create-pr/SKILL.md) supports GitHub without ClickUp coupling. Check the user's authorization before creating or changing remote resources.

For pull requests, `pr open` supports GitHub remotes. `pr list`, `pr status`,
and `pr comments` report that GitHub remotes are unsupported. See the [pr command
reference](../../README.md#pr).
