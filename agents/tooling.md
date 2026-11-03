# Local tooling for agents

Check `command -v cmds` first. If available, use `cmds --list` or `cmds --json` for read-only discovery, then consult `<command> --help` when supported and the [README](../README.md) before use. Discovery lists capabilities; it does not authorize execution or writes. If local execution is unavailable, consult the repository documentation and ask for the necessary context rather than assuming a command or its credentials are available.

For authenticated internal tasks, prefer existing, appropriate CLI utilities and skills over raw unauthenticated WebFetch. Follow the user's authorization and obtain explicit approval for writes when needed. Tokens in `alias/.env` are deliberately not exported by shell startup; utilities load only what they need on demand. Never reveal, echo, or export credentials. Follow the canonical [credential safety policy](security.md).

Consult the relevant guide on demand:

- [ClickUp](integrations/clickup.md)
- [Azure DevOps](integrations/azure-devops.md)
- [GitHub](integrations/github.md)
- [Git](integrations/git.md)

The [skill inventory](../README.md#shared-ai-skills) describes other available workflows.
