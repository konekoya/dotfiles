# ClickUp

The task ID is the last path component of task URLs such as `https://app.clickup.com/t/<workspace>/<id>` or `https://app.clickup.com/t/<id>`. The `clickup` command accepts an ID or URL: `clickup task <id|url> --json` reads one task; `clickup open` and `clickup snapshot` read task lists. Task JSON preserves its existing fields and includes `assignees`, an array of `{id, username}` objects with IDs normalized to decimal strings. Use `clickup comments <id|url> [--json] [--limit N]` to read task comments, newest first (25 by default). JSON contains `id`, `author`, `date` in Unix milliseconds, and `text`. A successful post prints its comment ID; if its outcome is uncertain, read comments before retrying. `clickup status` changes a task's status, `clickup comment` posts a comment, and `clickup assign <id|url> --me` adds the authenticated user as an assignee; each writes and requires authorization for that requested action.

`clickup comment <id|url> <file|->` accepts simple bold, inline code, HTTP(S) links,
flat bullet lists, sequential numbered lists starting at 1, and plain fenced code
blocks. One to three `#` heading markers become a bold line. Nested, ambiguous,
malformed, and other unsupported syntax stays literal, including language-tagged
code fences. ClickUp documents structured comment blocks in its formatting guide,
while the Create Task Comment reference lists only `comment_text` as required.
Endpoint acceptance requires a real-service check; if blocks cannot be used, the
implementation must return to plain-text posting. It does not retry automatically.

`clickup assign` skips the write when the authenticated user is already assigned. Otherwise it adds only that user and preserves other assignees. It prints `Assigned: <task-id>` after confirming the response contains the user and every preexisting assignee, or `Already assigned: <task-id>` when no write was needed. If a write cannot be confirmed, check the task before retrying; the CLI does not retry automatically. For agent handoffs, a task read or session start alone does not authorize assignment. If no one is assigned, add yourself only when explicit tracker-write authorization covers it. If other people are assigned, ask the owner before adding yourself. Combine that question with any needed authorization to change status. GitHub-only tasks do not use ClickUp.

Docs use a different URL shape, `https://app.clickup.com/<workspace-id>/v/dc/<doc-id>/<page-id>`, and `clickup doc` takes the bare ids, not the URL. `clickup doc pages <doc-id>` reads a Doc's page tree. `clickup doc page-create` and `clickup doc page-update` write: create adds a page or subpage, and update replaces a page's whole content, so run them only for the Doc and page the user named and never on an existing page without explicit authorization. The CLI cannot delete pages or attach files. The workspace id comes from `CLICKUP_WORKSPACE_ID`, or from the token's workspaces when it has exactly one; with several, the command stops and lists them for the user to choose.

`CLICKUP_API_TOKEN` is loaded on demand, not exported by shell startup. Do not reveal it. See the [command reference](../../README.md#clickup) for arguments and [local-env](../../README.md#local-env) for loading behavior. The [create-clickup-task skill](../../skills/create-clickup-task/SKILL.md) creates tasks; the [create-pr skill](../../skills/create-pr/SKILL.md) can link an existing task in its Azure DevOps workflow. Follow their instructions and the user's authorization before writing.
