# ClickUp

The task ID is the last path component of task URLs such as `https://app.clickup.com/t/<workspace>/<id>` or `https://app.clickup.com/t/<id>`. The `clickup` command accepts an ID or URL: `clickup task <id|url> --json` reads one task; `clickup open` and `clickup snapshot` read task lists. `clickup status` changes a task's status and `clickup comment` posts a comment: both write and require authorization for the requested action.

`CLICKUP_API_TOKEN` is loaded on demand, not exported by shell startup. Do not reveal it. See the [command reference](../../README.md#clickup) for arguments and [local-env](../../README.md#local-env) for loading behavior. The [create-clickup-task skill](../../skills/create-clickup-task/SKILL.md) creates tasks; the [create-pr skill](../../skills/create-pr/SKILL.md) can link an existing task in its Azure DevOps workflow. Follow their instructions and the user's authorization before writing.
