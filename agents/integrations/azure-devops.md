# Azure DevOps

Use `ado-rest context` to inspect the selected repository context and `ado-rest GET` for supported reads. `ado-rest` also supports write methods; execute them only when the user has authorized the specific action. See the [command reference](../../README.md#ado-rest) and [profile setup](../../README.md#azure-devops-work-and-personal-accounts).

Profiles are selected per repository and bound to an organization. The selected fetch and push remotes must identify the same repository; a profile/organization mismatch fails closed. Do not redirect a repository with an environment override or switch Azure accounts to make a request work. Consult the [create-pr](../../skills/create-pr/SKILL.md) and [merge-pr](../../skills/merge-pr/SKILL.md) skills for their workflows.

Use `pr list`, `pr status [ID] [--watch] [--interval SECONDS] [--json]`,
`pr comments [ID]`, and `pr open` for PR operations. See the [pr command
reference](../../README.md#pr) for details.
