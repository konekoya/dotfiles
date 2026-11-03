# Local tooling for agents

Nothing here asks you to run a command, load a secret, or call an API when a session starts. Act only when the user's task needs it.

- Discovery: if `command -v cmds` succeeds, `cmds --list` or `cmds --json` lists the local commands (read-only) and `<command> --help` describes one where supported. Discovery lists capabilities; it does not authorize running them or writing anything.
- The dotfiles repository is the parent of the directory that holds `cmds`. Read its `README.md` and only the on-demand guide the task needs: `agents/integrations/clickup.md`, `azure-devops.md`, `github.md` or `git.md`.
- ClickUp: for a task URL or ID, read it with `clickup task <id|url> --json`. `clickup status` and `clickup comment` write and need the user's authorization.
- Azure DevOps: use `ado-rest` (`ado-rest context` shows the parsed repository profile) instead of `az repos` or hand-built authenticated requests. GitHub: use `gh-auth`, not bare `gh`.
- Multi-step work (pull requests, commits, ClickUp tasks, branch cleanup): prefer the existing skills listed in the README section "Shared AI skills" over ad hoc command sequences.
- For authenticated internal systems, prefer these CLIs and skills over raw unauthenticated web fetches, and get explicit approval before writes.
- Tokens in `alias/.env` are deliberately not exported by shell startup; each command loads only what it needs. Never read that file, and never reveal, echo, export, or ask the user to paste a token. Follow the credential safety policy (`agents/security.md`), which is installed next to this guidance.
- If a command is missing or no local shell is available, check PATH and whether `install.sh` has run in the dotfiles repository, or tell the user what you cannot do. Do not work around it by asking for credentials.
