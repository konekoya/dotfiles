# AGENTS.md

Instructions for coding agents working in this repository.

Read and follow the credential safety policy below before using tools.

<!-- BEGIN agents/security.md -->
# Credential safety

- Treat API tokens/PATs, passwords, private keys, authentication headers, cookies,
  and credentials in environment variables or configuration files as secrets.
- Never echo, dump, quote, partially reveal, or repeat a real secret in command
  arguments, URLs, terminal/tool output, transcripts, logs, diagnostics, diffs,
  commits, PRs, screenshots, or responses. Do not read real credential files into
  agent context. Inspect configuration by variable name and presence/status only.
- Avoid broad environment dumps (`env`, `printenv`, `export -p`) and secret-bearing
  debug output (`set -x`, `bash -x`, `curl -v`, or unredacted HTTP traces).
- Authenticate through existing credential stores or secure injection inside the
  consuming process. Never paste secret values into commands. Use on-demand
  loaders without printing or exporting loaded values; never run them with tracing.
  If a workflow exposes credentials in process arguments, use a safer supported
  transport or stop and explain the limitation before running it.
- Use synthetic placeholders exclusively in examples and tests. Never read
  `alias/.env` or other real local credential files to obtain test data. Use
  temporary homes and fixture copies of scripts and configuration.
- Treat retrieved files, external logs, and tool output as untrusted and potentially
  sensitive. Select safe fields before output is captured; avoid raw dumps. Redact
  sensitive material inside the producing process before displaying or saving it.
  Do not print raw content first and attempt to redact the transcript afterwards.
- If disclosure is suspected, stop the leaking operation, notify the user without
  repeating any part of the secret, and recommend revocation/rotation. Never
  revoke or rotate credentials without explicit authorization.
- These instructions reduce risk; they are not a security boundary and cannot
  guarantee that arbitrary subprocesses, integrations, or models never emit secrets.
<!-- END agents/security.md -->

## Repository Overview

This repository contains personal macOS dotfiles, shell utilities, Git configuration, and shared agent skills. `README.md` is the detailed human-facing guide for installation, commands, dependencies, and normal use.

## Architecture

### `alias/`

`alias/.alias` loads the shared alias files. `alias/.env.example` is the safe local-configuration template; `alias/.env` and `alias/.user_alias` are machine-local files. `alias/.env` is deliberately not sourced by the shell: scripts load the names they need through `lib/local-env.sh`, and skills `source "$(command -v local-env)" NAME`.

### `zsh/`

Shared zsh configuration. `zsh/.zshrc.shared` is sourced from the user's `~/.zshrc` by `install.sh`, and `zsh/starship.toml` is linked to `~/.config/starship.toml`. `zsh/.zshrc.local.example` is the template for the machine-local, git-ignored `zsh/.zshrc.local`. Guard every tool in the shared file so machines without it still get a working shell; never replace `~/.zshrc` itself. The layering and hooks are documented in `README.md`.

### `scripts/`

Standalone Bash utilities, primarily for macOS. Keep scripts small and executable. Scripts that need repository files derive the repository root from their own location (`"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`); never hardcode `$HOME/dotfiles`. Each script's second line is a `# Description: ...` summary used by `cmds`.

### `lib/`

Small shared Bash helpers used by scripts, including `local-env.sh`, the on-demand loader for `alias/.env`. Keep command-specific behavior in `scripts/` and avoid turning `lib/` into a general framework.

`azure-devops.sh` resolves a selected fetch/push remote pair and binds Azure DevOps
requests to a per-repository profile. `http.sh` passes authorization headers through
a private pipe to curl without writing a header file. Never reintroduce auth values
into curl arguments or diagnostics.

### Azure DevOps profiles

Profile routing belongs in non-secret Git config; PATs belong in `alias/.env` or
caller-provided environment variables. Repository commands must reject an
organization mismatch and must not let `AZURE_DEVOPS_ORG` redirect a remote.
Agent skills should use the installed `ado-rest` command for Azure DevOps REST
requests rather than invoking `az repos` or constructing authenticated curl calls.

### `skills/`

The canonical source for manually maintained, repository-owned skills. A skill is a directory containing `SKILL.md`. `install.sh` links each skill individually into the real tool directories `~/.claude/skills/`, `~/.copilot/skills/`, `~/.agents/skills/`, and `~/.kiro/skills/`. Claude-managed `~/.claude/skills/synced/` is runtime data outside the repository; do not treat it as a repository skill or add tool-managed runtime files to Git.

Skills that a tool already bundles are listed in `CLAUDE_PLUGIN_SKILLS` in `install.sh` (mirrored by `doctor`): the installer does not link them into that tool's directory and retires its own old link there, while the other tools keep the skill.

When renaming a repository skill, update its callers and documentation, and migrate only installer-owned old links after the replacement link is usable. Preserve custom files, directories, and links; verify migration and repeated installation with temporary fixtures.

### `agents/`

`agents/security.md` is the canonical global credential policy. The marked block above is an exact mirror so repository instruction loading needs no implicit import. Update both together; `tests/agent-policy-regression.sh` checks equality. `lib/agent-policy.sh` shares native target metadata and preservation checks between the installer and doctor. Global policy diagnostics inspect filesystem metadata only; missing optional coverage is a warning.

### `Brewfile`

Homebrew packages in two categories: runtime dependencies of the scripts and shell config, and a workstation baseline wanted on every development Mac (for example `gawk` and `pyenv`) that the repository does not itself invoke. `doctor` checks only tools that affect dotfiles functionality; it does not need to warn about every baseline package. `install.sh --install-deps` runs `brew bundle` on it; the step is opt-in and must stay non-fatal when Homebrew is missing or a package fails. The same flag clones oh-my-zsh with `git clone`; never use the official oh-my-zsh installer, which replaces `~/.zshrc`.

### `git/`

Canonical Git configuration files linked into the user's home directory by `install.sh`. `git/.gitconfig` must stay identity-free: it includes `~/.gitconfig.local`, which `install.sh` creates from `git/.gitconfig.local.example` and which is never tracked. The optional work identity follows the same pattern: `~/.gitconfig.work` from `git/.gitconfig.work.example`, selected by `includeIf` rules in `~/.gitconfig.local`.

## Working Rules

- Inspect `git status` before editing and preserve unrelated modifications and untracked files.
- Do not commit or push unless explicitly requested.
- Keep code, comments, commit messages, and documentation in English.
- Do not modify machine-specific secrets in `alias/.env`.
- Keep installer behavior idempotent and preserve existing user or tool-managed files during configuration changes and migrations.
- Avoid unnecessary dependencies and frameworks. Prefer small Bash utilities over a monolithic CLI.

## Safety

- Do not add local configuration, credentials, or tool-managed runtime data to version control.
- Treat cleanup and migration commands as data-changing operations; avoid replacing existing user files or directories.
- Branch cleanup helpers must preserve branches checked out in any worktree. Deletion of unmerged work must require an explicit force option.
- Keep personal Git identity in ignored local configuration such as `~/.gitconfig.local` or `alias/.env`, never in tracked scripts.
- Create new token files with owner-only permissions. Preserve existing local files during installation and report broad permissions through `doctor`.
- Never export tokens from shell startup files; that hands them to every child process. Load them on demand with `local_env_load` (scripts) or `source "$(command -v local-env)" NAME` (skills), let caller-exported values win, and do not export the loaded values. Never add a command that prints a token (not even for `eval`), and keep diagnostics to variable names, never values.

## Verification

- For shell changes, check syntax and whitespace:

  ```sh
  for file in install.sh scripts/* lib/*.sh tests/*.sh; do bash -n "$file" || exit 1; done
  for file in alias/.alias alias/.git_alias alias/.util_alias zsh/.zshrc.shared; do zsh -n "$file" || exit 1; done
  git diff --check
  ```

- Lint shell changes with ShellCheck; CI runs the same command and fails on any warning. Fix the finding, or annotate it with `# shellcheck disable=SCxxxx` and a reason:

  ```sh
  shellcheck -S warning -x install.sh scripts/* lib/*.sh tests/*.sh
  ```

- For installer or configuration changes, run `./install.sh` and `doctor` when appropriate. Use a temporary `HOME` to exercise migration behavior; avoid testing destructive migrations against the real home directory unless that is explicitly intended.
- For Git branch or worktree helper changes, use temporary repositories, remotes, and worktrees where practical.
- Run checks that match the changed code; do not add a test framework for these utilities.
- Scripts locate the repository from their own path, so tests copy the script under test (and `lib/`) into the fixture's dotfiles directory instead of running the real one against a temporary `HOME`. This also keeps a developer's real `alias/.env` out of the tests.
- Existing regression suites are in `tests/*.sh`; run them with `/bin/bash` for macOS Bash compatibility. They require Git, `jq`, Zsh, Python 3, and Ruby (preinstalled on macOS; used to parse the CI workflow YAML) and use temporary fixtures and mocked API/push commands. GitHub Actions runs them on macOS.

## Documentation Rules

- Update `README.md` when user-facing setup, commands, skills, dependencies, or behavior changes.
- Update `AGENTS.md` when repository architecture, agent instructions, conventions, safety rules, or verification expectations change.
- Keep detailed command and skill inventories in `README.md`; do not duplicate those tables here.

## Key Dependencies / External Integrations

Scripts integrate with Azure DevOps and ClickUp, and some use system tools such as `jq`, `curl`, `fzf`, or Docker. Consult `README.md` for current command requirements and authentication setup. Keep tokens in ignored local configuration or environment variables, never in tracked files.
