# TODO

Skills, Git config, aliases, scripts, zsh and prompt config, and per-machine `alias/.env` already share well across laptops. Nothing is open.

## Evaluated, not planned

Revisit these only if the cost of setting them up by hand starts to hurt.

- **Share Claude Code global config.** A shared `settings.json` can only be merged, not symlinked, because `statusLine` points into a plugin cache path with a hash and `hooks` are written by plugins (Orca, caveman) that rewrite them. The shareable keys (`enabledPlugins`, marketplaces, `editorMode`, preferences) are small and quick to set by hand. A global `CLAUDE.md` does not exist yet.
- **Share non-skill config for Copilot and Codex** (instructions, MCP configs).

When an item is implemented, update `README.md` and `AGENTS.md` as their documentation rules require, and add coverage to the matching `tests/*.sh` suite.
