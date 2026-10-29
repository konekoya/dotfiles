# dotfiles

Personal dotfiles for macOS, focused on Azure DevOps workflows. Includes Git configuration, modular shell aliases, and utility scripts.

## Installation

```sh
git clone https://github.com/<your-username>/dotfiles ~/dotfiles
cd ~/dotfiles
./install.sh
```

`~/dotfiles` is only the suggested location. `install.sh`, `doctor`, `bookmark`, and `config-git` find the repository from their own path, so you can clone it anywhere (for example `~/code/dotfiles`). The path must not contain spaces or shell special characters; `install.sh` refuses to run otherwise. If you move the repository later, run `install.sh` again so `~/.zshrc` points at the new location, and delete the stale lines for the old one.

`install.sh` adds the alias source, shared zsh config source, and scripts directory to `~/.zshrc` when those lines are missing. They are written as `~/...` (or `$HOME/...` for the PATH entry) when the repository is under your home directory, and as absolute paths otherwise. Apply the changes in the current shell with:

```sh
source ~/.zshrc
```

To also install missing command-line tools with Homebrew (see [Dependencies](#dependencies)) and oh-my-zsh:

```sh
./install.sh --install-deps
```

## New laptop checklist

`install.sh` covers everything that lives in the repository. These items cannot, because they are secrets or per-account logins. Do them in order; `doctor` at the end shows what is still missing.

1. **Homebrew and Git.** Install Homebrew (https://brew.sh); it also installs the Xcode command line tools, which provide Git.
2. **Clone and install.** Clone over HTTPS because no SSH key exists yet, then run `./install.sh --install-deps` (see [Installation](#installation)) and `source ~/.zshrc`.
3. **SSH keys.** Copy your existing keys to `~/.ssh/` or create new ones, then register the public keys with GitHub and Azure DevOps (User Settings → SSH public keys):

   ```sh
   chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_*        # private keys must be owner-only
   chmod 644 ~/.ssh/*.pub
   ssh -T git@github.com                            # expect a greeting with your username
   ssh -T git@ssh.dev.azure.com                     # expect "Shell access is not supported" (that means auth worked)
   ```

4. **age key.** Copy `~/.age/keys.txt` from a trusted machine (never from the repository) and restrict it with `chmod 600 ~/.age/keys.txt`. The `SOPS_AGE_KEY_FILE` line in `~/.zshrc` points at it (see [What goes where](#what-goes-where)).
5. **CLI logins.**

   ```sh
   gh auth login
   az login
   ```

6. **Tokens.** Fill in `alias/.env` (see [Tokens & Local Configuration](#tokens--local-configuration)): `CLICKUP_API_TOKEN`, Azure DevOps profile PATs if needed, and the work identity for `config-git`.
7. **Git identity.** Edit `~/.gitconfig.local` with your name and email, and enable the Azure DevOps rules if you use a separate work identity (see [Git Config](#git-config)).
8. **Work notes (optional).** Set `WORK_NOTES_REPO` in `alias/.env` and run `./install.sh` again; it needs the SSH key from step 3 (see [Work notes](#work-notes)).
9. **Verify.** Run `doctor`; every line should pass or explain what is left.

## What `install.sh` does

- Creates symlinks for `~/.gitconfig` and `~/.gitignore_global` when they are missing. Correct links are left in place; existing files and unrelated or broken symlinks are preserved with a warning.
- Creates `~/.gitconfig.local` from `git/.gitconfig.local.example` if it doesn't exist. It holds your Git `user.name` and `user.email`, lives outside the repository, and is never overwritten
- Creates `~/.gitconfig.work` from `git/.gitconfig.work.example` if it doesn't exist. It is optional and unused until you enable the Azure DevOps `includeIf` rules (see Git Config)
- Creates real skills directories and links each repository-managed skill separately for Claude Code, GitHub Copilot CLI, Codex, and Kiro CLI
- Links the canonical credential safety policy at native global instruction entry points when vacant; preserves conflicts and reports manual integration steps (see [Agent credential safety](#agent-credential-safety))
- Creates `alias/.user_alias` and `alias/.env` if they don't exist; new `.env` files have owner-only permissions (`0600`)
- Links `zsh/starship.toml` to `~/.config/starship.toml` when it is missing; an existing file or unrelated symlink is preserved with a warning
- Creates `zsh/.zshrc.local` from `zsh/.zshrc.local.example` if it doesn't exist (per-machine zsh overrides, not tracked)
- With `--install-deps`, runs `brew bundle` on `Brewfile` to install missing Homebrew packages; without the flag it ends with a tip about the option. Skipped with a warning when Homebrew is not installed
- With `--install-deps`, clones oh-my-zsh into `~/.oh-my-zsh` when that path does not exist, before the plugin clones below. It uses `git clone` rather than the official installer because that installer replaces `~/.zshrc`; an existing `~/.oh-my-zsh` is never touched
- Clones the optional private work-notes repository from `WORK_NOTES_REPO` when its directory is missing, then links what its `links.tsv` lists. Existing paths are preserved, and a failed clone is reported without printing the URL (see [Work notes](#work-notes))
- Adds missing alias, `zsh/.zshrc.shared`, and scripts PATH configuration to `~/.zshrc`; commented settings and commands that merely mention these paths do not count

## Shared zsh and prompt

A new laptop gets the same shell behavior and prompt after `./install.sh`, while each machine keeps room for its own tweaks. `install.sh` adds one line, `source ~/dotfiles/zsh/.zshrc.shared`, to `~/.zshrc` and never rewrites the rest of that file.

### Layers

Later layers win over earlier ones.

| Layer | File | Tracked | Purpose |
|-------|------|---------|---------|
| 1. Per-machine early overrides | `zsh/.zshrc.local` | no (created from `zsh/.zshrc.local.example`) | Loaded first, before oh-my-zsh and the prompt |
| 2. Shared base | `zsh/.zshrc.shared` | yes | oh-my-zsh theme and plugins, `set -o vi` with a short `KEYTIMEOUT`, az completion, starship init, fzf key bindings |
| 3. Machine shell file | `~/.zshrc` | no | Sources the shared file; anything below that line runs after it |
| Prompt | `zsh/starship.toml` linked to `~/.config/starship.toml` | yes | Same prompt on every laptop |
| Aliases and tokens | `alias/.user_alias`, `alias/.env` | no | Per-machine aliases and secrets |

### What goes where

- `zsh/.zshrc.shared`: anything every laptop should have. Guard each tool with `command -v` or `[ -f ]` so a missing tool does not break the shell.
- `zsh/.zshrc.local`: anything that must be set before oh-my-zsh or the prompt loads. Supported hooks:
  - `DOTFILES_EXTRA_PLUGINS=(docker kubectl)` appends plugins to the shared oh-my-zsh plugin list.
  - `ZSH_THEME` overrides the fallback theme (only visible without starship).
  - `STARSHIP_CONFIG=<path>` points starship at another config on this machine.
  - An optional, commented `pyenv init` block; see the pyenv bullet in [Design decisions](#design-decisions).
- `~/.zshrc` below the shared source line: anything that must run after the shared setup (Kiro blocks, Docker completions, local PATH additions, `SOPS_AGE_KEY_FILE`).

### Design decisions

- **The prompt is starship.** `ZSH_THEME` stays `robbyrussell` only as a fallback; `starship init zsh` runs after oh-my-zsh and replaces the theme prompt. Prompt colors and layout belong in `zsh/starship.toml`, so one edit reaches every laptop.
- **`~/.zshrc` is not symlinked.** Tools such as Kiro and Docker edit it, and it holds machine-only blocks. The shared file is sourced instead.
- **Existing oh-my-zsh setups keep working.** The shared file skips oh-my-zsh when `omz` is already defined, then loads any missing shared plugins directly. Syntax highlighting loads after the other shared shell setup.
- **Double loading is avoided.** The shared file checks for the plugin functions before sourcing fallback plugin files, so plugins already loaded by `~/.zshrc` are left alone.
- **Starship has no include mechanism.** A per-machine prompt difference needs a second toml selected with `STARSHIP_CONFIG` in `zsh/.zshrc.local`.
- **Startup stays cheap.** The az completion reads `$HOMEBREW_PREFIX` (set by `brew shellenv` in login shells) and only runs `brew --prefix` when it is unset. `KEYTIMEOUT=1` removes the 0.4s Esc delay of vi mode; set a different value in `~/.zshrc` below the shared source line if a slow SSH link breaks arrow keys.
- **fzf integration is optional.** When `fzf` 0.48+ is installed and the shell has a terminal, `fzf --zsh` adds Ctrl-R (history), Ctrl-T (files), Alt-C (directories), and `**<Tab>` completion in the emacs, vi-insert, and vi-command keymaps. It loads before syntax highlighting. Without fzf, or with an older one, the shell starts normally with the default bindings.
- **pyenv is installed but opt-in.** The Brewfile installs it as a workstation baseline tool, but the shared config never initialises it, so every shell avoids the cost of `pyenv init` on machines that do not use it. Without initialisation, pyenv-managed versions do not take precedence over the system or Homebrew Python. Where you need per-project Python versions, uncomment the `pyenv init` block from `zsh/.zshrc.local.example` in your `zsh/.zshrc.local`. The installer never changes an existing `zsh/.zshrc.local`, so machines created earlier must copy that block by hand.
- **Existing files are preserved.** The installer never replaces an existing `~/.config/starship.toml` or `zsh/.zshrc.local`; `doctor` warns when the shared prompt is not linked.

### Troubleshooting prompt icons

The Brewfile installs Hack Nerd Font, but installing a font does not select it in a terminal app. If Starship's Git branch icon appears as a box or question mark, set the terminal font family to `Hack NF`. In VS Code, add this to User Settings:

```json
"terminal.integrated.fontFamily": "'Hack NF'"
```

In Warp, open **Settings → Appearance → Text, fonts, & cursor** and select **Hack NF**. Warp may need a restart after installing a font before it appears in the list. Each terminal app and profile may need its own font selection; open a new terminal and check the prompt glyph afterward. See the [VS Code terminal font setting](https://code.visualstudio.com/docs/terminal/appearance), [Warp font settings](https://docs.warp.dev/terminal/appearance/text-fonts-cursor), and [Nerd Fonts family-name guidance](https://github.com/ryanoasis/nerd-fonts/wiki/FAQ-and-Troubleshooting).

### Migrating a laptop with a hand-written `~/.zshrc`

1. Run `./install.sh`; it appends the shared source line and creates `zsh/.zshrc.local`.
2. Remove the lines from `~/.zshrc` that the shared file now covers (oh-my-zsh theme, plugins and source, `set -o vi`, az completion, `starship init`).
3. Move machine-only settings that must load early into `zsh/.zshrc.local`.
4. Replace the local prompt file with the shared one: `mv ~/.config/starship.toml ~/.config/starship.toml.bak && ./install.sh`.
5. Run `doctor`, then open a new shell.

## Shared AI Skills

`skills/` is the canonical source for manually maintained skills shared by Claude Code, GitHub Copilot CLI, Codex, and Kiro CLI. `install.sh` keeps `~/.claude/skills/`, `~/.copilot/skills/`, `~/.agents/skills/`, and `~/.kiro/skills/` as real directories and creates one symlink per skill in each. It only links directories containing `SKILL.md`, and it preserves unrelated tool-managed files and skills.

Claude Code ships its own `skill-creator` plugin, so the installer does not link the repository copy into `~/.claude/skills/`; it removes an existing installer-owned link there and keeps linking the skill for GitHub Copilot CLI, Codex, and Kiro CLI, which have no such plugin. Custom files, directories, and links to other sources are preserved, and `doctor` warns if the duplicate link reappears.

Claude Code manages `~/.claude/skills/synced/` itself. That runtime data stays outside the repository. If an older installation has Claude's `synced/` data under `claude/skills/synced/`, `install.sh` moves it to `~/.claude/skills/synced/` after replacing the old parent symlink; if both locations already exist, it preserves both and warns.

Repository-managed skills:

| Skill | Purpose |
|-------|---------|
| `address-pr-review` | Fetch Copilot review comments from an Azure DevOps PR, discuss fixes, then apply approved fixes and reply to the threads |
| `babysit-pr-checks` | Resolve conflicts and PR feedback, run checks, push, and monitor/fix CI until the Azure DevOps PR is green |
| `create-pr` | Detect GitHub or Azure DevOps from the selected remote, run repository checks, push, and create or update a PR using `gh` or the shared Azure DevOps REST helper; optional ClickUp linking/status updates apply only to Azure DevOps |
| `create-clickup-task` | Create a ClickUp task directly or from the current branch/PR with formatted lists and optional reviewer verification steps, choose its type and placement, and optionally link the PR without losing formatting |
| `create-git-commit` | Draft a Conventional Commit message from the changes and commit after confirmation |
| `fix-npm-audit` | Triage `npm audit` findings by severity, ask before applying fixes, then commit |
| `fix-npm-vet` | Run `npm run vet` (lint, typecheck, format, and tests), fix reported issues, then commit |
| `implement-spec` | Implement a spec while maintaining `implementation-notes.html` |
| `learn-quiz` | Teach a topic in stages and check understanding with quizzes |
| `skill-creator` | Create, update, and evaluate shared agent skills (GitHub Copilot CLI, Codex, and Kiro CLI only) |
| `merge-pr` | Squash-merge ready GitHub or Azure DevOps PRs in a safe order after verifying approvals and current checks, then close out ClickUp (Azure DevOps) and worktrees |
| `squash-git-commits` | Squash feature-branch commits into one relative to the selected PR or repository target branch |
| `summarize-pr` | Summarize branch changes and update the Azure DevOps PR description |
| `sync-work-notes` | Pull the private work notes, update decisions, reports, and memory from the current session, then commit on a branch and open a PR for review |

To add a shared skill, create `~/dotfiles/skills/my-skill/SKILL.md` and run `./install.sh`. The installer creates all four per-skill links; no manual links are needed.

`create-pr` replaces `create-azure-pr`. Run `./install.sh` after updating: it links the new skill and removes only old links pointing to this repository, preserving custom skill files and links. GitHub uses `gh auth login`, repository PR templates, and English by default, with no ClickUp prompts or API calls. Azure DevOps keeps its optional existing-task integration and Traditional Chinese description default; explicit user and repository instructions take precedence.

## Agent credential safety

`agents/security.md` is the canonical policy for preventing disclosure through
agent context, command output, process arguments, transcripts, logs, and responses.
It covers presence-only inspection, synthetic test data, secure authentication,
and incident response without repeating or rotating secrets. `AGENTS.md` contains
an exact marked mirror so repository guidance includes the whole policy without
depending on a tool-specific import. When editing the canonical file, copy its
contents into that block too; the regression suite rejects drift.

### Global instruction integration

`./install.sh` creates the following individual symlinks to `agents/security.md`.
It creates missing directories even if the CLI is not installed. No whole agent
directory is linked, and no settings, authentication, or runtime files are edited.
These are instruction entry points, separate from the shared skill directories.

| Agent | Installed global entry point | Loading behavior and constraints |
|-------|------------------------------|----------------------------------|
| Codex CLI | `${CODEX_HOME:-~/.codex}/AGENTS.md` | Global instructions load before project instructions. A global `AGENTS.override.md` takes priority; installation skips Codex when that path exists, even if empty or dangling. Project overrides and instruction size limits can affect coverage. |
| Claude Code | `${CLAUDE_CONFIG_DIR:-~/.claude}/rules/dotfiles-security.md` | User rules without `paths` load for every project. The main `CLAUDE.md` is left intact. User rules support symlinks; disabled/excluded user instructions can prevent loading. |
| Kiro CLI | `~/.kiro/steering/dotfiles-security.md` | Global steering is always included by default. Custom profiles can omit default resources; verify the active agent. Workspace steering can override global guidance. |
| GitHub Copilot CLI | `${COPILOT_HOME:-~/.copilot}/copilot-instructions.md` | Personal instructions apply across repositories and combine with repository instructions. An existing personal instruction file requires manual integration. |
| Orca ADE | None | An independent global instruction-loading contract could not be verified. Do not assume a wrapped CLI, IDE, or hosted agent inherits these files; verify the active harness separately. |

Official sources checked on October 16, 2026:

- [Codex instruction discovery](https://developers.openai.com/codex/guides/agents-md/): one global file, then project files from the project root down to the working directory; default instruction limit is 32 KiB. A Markdown link or Claude-style `@` reference is not a verified Codex import mechanism.
- [Claude Code memory and user rules](https://code.claude.com/docs/en/memory) and [configuration directory override](https://code.claude.com/docs/en/env-vars): project instructions use `CLAUDE.md`/`.claude/CLAUDE.md`; current releases also have conditional `AGENTS.md` support. The global rule avoids depending on that version-specific fallback.
- [Kiro steering](https://kiro.dev/docs/steering/) and [custom agent resources](https://kiro.dev/docs/custom-agents/configuration-reference/): the steering page requires explicit resources for custom agents, while the configuration reference describes inheritance unless `chat.disableInheritingDefaultResources` is enabled. Treat custom profile coverage as unverified until checked. A custom agent can explicitly include an absolute `file://` path to the installed policy in its `resources` array.
- [Copilot CLI custom instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions): repository `AGENTS.md`, `.github/copilot-instructions.md`, and modular instructions also load. The personal file is an unconditional entry point without an extra environment variable or import. Modular user instructions are another documented option for manual integration.

### Existing machines and custom instructions

Run `./install.sh` after updating this repository. Correct links are retained;
regular files, directories, and unrelated or broken links at the target are
preserved with a warning. Existing parent directory links or conflicting files
also prevent policy provisioning. Nothing is appended to existing instructions.
The installer never removes or replaces a policy link to a different checkout.

If a target is occupied, keep it and integrate the policy yourself after reviewing
your instructions locally. Claude supports an additional global rule without
changing `CLAUDE.md`; Copilot supports modular user instructions under
`~/.copilot/instructions/**/*.instructions.md`. Codex has one active global file:
include the policy text in that file yourself and keep it synchronized. A plain
link to the policy does not guarantee loading. Do not dump custom instructions or
credential files into an agent transcript to perform this review.

Profile directory overrides must be absolute paths and must be present in the
environment of both the installer and the CLI. The installer does not inspect
agent settings to discover additional profiles. Symlinked directory ancestors
are conservatively skipped. Re-running the installer in another checkout leaves
the old global links untouched for manual migration. Links track canonical edits
automatically, but a moved or deleted checkout breaks them; review and migrate
them yourself without overwriting user configuration.

`doctor` reports missing, conflicting, or masked optional policy links as warnings,
not core setup failures. Its policy checks inspect filesystem metadata only and
never open instruction bodies or credentials. A correct link is reported as a
link check, not proof that a CLI loaded or obeyed it. The rest of `doctor` retains
its existing local-configuration presence checks.

### Verification and security limits

Run `/bin/bash tests/agent-policy-regression.sh` for synthetic fixture coverage;
the installer and doctor regression suites also exercise the integration. Tests
use copied scripts, temporary homes, and synthetic values, with no real API calls.
They verify native entry-point contents and live policy updates, preservation,
overrides, warning semantics, and secret-free output. They do not prove model
adherence. Runtime CLI verification, where performed, is recorded in the PR.

For a CLI upgrade, use an empty temporary home/profile and project with synthetic
instructions to check loading. Claude's `/context`, Kiro's `/context show` (where
available), and Copilot's `/instructions` expose instruction sources. Codex can
report active instructions in a synthetic session. Avoid enabling raw debug or
session logs against real configurations. Restart sessions after policy changes.

Instructions reduce accidental disclosure; they cannot guarantee arbitrary models,
subprocesses, MCP services, or external logs never emit secrets. Projects can
conflict with global guidance, profiles can bypass it, and local policy files are
editable. PR #15's on-demand, non-exporting credential loading remains necessary.
Existing workflows that pass tokens as process arguments still need separate
transport hardening; the policy tells agents to choose a safe transport or stop.

Stronger enforcement is separate work: [Claude PreToolUse hooks](https://code.claude.com/docs/en/hooks)
can deny a tool call, [Kiro permissions](https://kiro.dev/docs/permissions/)
can restrict capabilities, and Copilot provides tool-deny flags. Narrow filesystem
restrictions or credential-safe request helpers could reduce exposure, but broad
shell blocking is bypassable and can break legitimate workflows. Post-output
redaction cannot undo disclosure already captured upstream. This installation
adds no hooks, permission changes, subprocess interception, or output rewriting.

## Work notes

Working notes that should follow you between machines but must not be public (project decisions, weekly reports, Claude Code project memory) live in a separate private repository. This repository stays the entry point: it knows how to fetch the notes and where to link them, while the notes repository owns its own content and layout.

Configure it in `alias/.env`:

```sh
export WORK_NOTES_REPO="git@github.com:<you>/work-notes.git"   # SSH; never embed a token in the URL
# export WORK_NOTES_DIR="$HOME/work-notes"                     # default
```

`install.sh` clones the repository when `WORK_NOTES_DIR` does not exist. If cloning fails, it asks you to verify `WORK_NOTES_REPO`, repository existence and access, Git authentication, and network connectivity before retrying. Git output stays hidden to avoid exposing the private repository URL.

After cloning, it reads `links.tsv` at the repository root. Each line has three whitespace-separated fields; `#` starts a comment:

```text
# kind          source            target
home            impress/weekly    work/impress-weekly
claude-memory   impress/memory    code/my-project
```

- `home` links `$HOME/<target>` to `<source>` in the notes.
- `claude-memory` links Claude Code's memory directory for the project at `$HOME/<target>` (`~/.claude/projects/<encoded path>/memory`) to `<source>`, so the assistant keeps its project memory on every machine. The project must be cloned at the same path relative to `$HOME`.
- Sources are relative to the notes root and targets relative to `$HOME`; absolute paths and `..` are rejected.
- A machine that keeps a project somewhere else adds `links.local.tsv` next to `links.tsv`, in the same format. Keep it out of Git with the notes repository's `.gitignore`, and commit a commented `links.local.tsv.example` there so each machine can copy it. Remove the old link before switching paths, because `install.sh` never replaces an existing one. A local entry replaces every shared entry with the same source, so the shared manifest keeps the common default path:

  ```text
  claude-memory   impress/memory    code/my-project
  ```

Existing targets are never replaced. To move an existing Claude memory directory into the notes, copy its files into the source directory, remove the original directory, and run `./install.sh` again. `doctor` fetches the notes and reports missing links, uncommitted notes, commits that are not pushed yet, and commits from another machine that are not pulled yet. The `sync-work-notes` skill pulls, updates the notes from the current session, commits on a notes branch, and opens a pull request; notes reach `main` only after you review and merge it. Run it at the end of a work session.

Keep secrets out of the notes exactly as in this repository: tokens stay in `alias/.env`, and remote URLs with credentials are never written down. The notes repository's own README describes what belongs in it.

## Aliases

Aliases live in `alias/` and are loaded via `alias/.alias`:

| File | Contents |
|------|----------|
| `.git_alias` | Git shortcuts (`gs`, `gl`, `gco`, `gc`, `gp`, `gg`, `gb`, `gd`, etc.) |
| `.util_alias` | macOS utilities — `ip`, `wifi`, `bye`, `server` |
| `.user_alias` | Per-machine aliases (gitignored — add your own here) |

The machine-local `.user_alias` file is optional; shared aliases still load without
errors when it is missing. `alias/.env` is never sourced during shell startup.

The `server` alias serves the current directory with `python3 -m http.server` on
port 8000, bound to localhost, and opens it in your browser. It requires Python 3.

### Common git aliases

| Alias | Command |
|-------|---------|
| `gs` / `gst` | `git status` |
| `gl` | `git pull` |
| `gco` | `git checkout` |
| `gcm` / `gcd` | Check out local `master` (fallback: `main`) / `develop` (fallback: `dev`) |
| `grm` / `grd` | Rebase onto local `master` (fallback: `main`) / `develop` (fallback: `dev`); accepts rebase arguments |
| `gc "msg"` | `git commit -m "msg"` |
| `ga` | `git add .` |
| `gp` | `git push` |
| `gg` | Pretty graph log |
| `gd` | `git diff` |
| `gb` | `git branch -a` |

These checkout and rebase shortcuts prefer the first branch when both exist and
print an error if neither exists. `grm` and `grd` do not fetch; update the local
base branch first when you need the latest upstream changes.

## Scripts

All scripts are in `scripts/` and available on `$PATH` after installation.

### `doctor`

Checks symlinks (including the starship config), shared skills, shell config, PATH, optional dependencies, Oh My Zsh plugin files, and the optional work notes (links from `links.tsv` and `links.local.tsv`, uncommitted changes, and unpushed commits; it fetches the notes the same way as the repository below and warns when another machine pushed changes you have not pulled).
Core setup failures produce a non-zero exit code; missing optional tools and
configuration are reported as warnings.
Shell checks recognize standalone `source`/`.` commands and `PATH` assignments
using `~`, `$HOME`, `${HOME}`, or the absolute home path. They do not execute
`~/.zshrc`. Local token-file permissions are checked without printing values.
Working Git config links may use absolute or relative paths. Existing files and
unrelated or broken links require manual review because the installer preserves them.

The Zsh plugin checks are static: they verify that each expected plugin entrypoint
is readable and non-empty, that the shared config contains the normal and
preloaded Oh My Zsh loading paths, and that `~/.zshrc` references the shared
config. Syntax highlighting must remain after the fzf integration. `doctor` does
not source user shell files or inspect the parent interactive shell, so these
checks do not prove that a plugin loaded in the current session. Missing plugin
directories at the default install path can be created with
`./install.sh --install-deps`; install plugins under an alternate `ZSH_CUSTOM`
path using the plugin setup for that path. The installer preserves existing
plugin directories, so inspect and move an incomplete directory aside before
reinstalling it. `doctor` honors exported `ZSH` and `ZSH_CUSTOM` values; it does
not source `zsh/.zshrc.local` to discover shell-only assignments.

When Starship is installed and `~/.zshrc` references the shared config, `doctor`
checks the standard macOS font directories for Hack Nerd Font filenames. A
matching file does not prove macOS registered it or that the active terminal
selected it; if no file is found, installation remains unverified. Follow
[Troubleshooting prompt icons](#troubleshooting-prompt-icons) to select the font.
It also fetches the repository's upstream (never prompting, giving up after a few
seconds offline, with a spinner on a terminal) and warns when the checkout is behind it; run `git pull` in the
repository and then `./install.sh` again to catch up. Fetching only refreshes
remote-tracking refs and never changes your working tree.

```sh
doctor
```

### `ado-rest`

Makes repository-scoped Azure DevOps REST requests with the repository's selected
organization profile. Agent skills use it for PR reads and writes so they do not
rely on Azure CLI organization defaults or place auth headers in curl arguments.

```sh
ado-rest context
ado-rest GET '/_apis/git/repositories/<repository>/pullrequests?api-version=7.1'
```

Use only Azure DevOps API paths under `/_apis/`. `POST`, `PATCH`, and `PUT`
require an explicit JSON body; `DELETE` may omit it. The command validates the
fetch/push remote pair and profile before sending a request.

### `pr`

Lists active Azure DevOps PRs created by you and assigned to you, across all projects in your org.

```sh
pr
```

Inside a repository, the organization comes from the selected Git remote. Outside
a repository, select an organization with `AZURE_DEVOPS_PROFILE` or the legacy
single-org pair `AZURE_DEVOPS_ORG` and `AZURE_DEVOPS_PAT`.

Repository commands use the matching profile selected with
`git config --local azure-devops.profile work-company-a`. `AZURE_DEVOPS_ORG` never replaces
an organization parsed from a remote.

**Requires:** `jq`, `curl`

### `pr-comments`

Fetches and displays PR comment threads for the current branch, or a specific PR.

```sh
pr-comments          # auto-detects PR from current branch
pr-comments <PR_ID>  # specific PR
```

Same auth and org resolution as `pr`. **Requires:** `jq`, `curl`

Automatic PR lookup uses the project and repository identified by the selected
remote and selects an active PR. Pass an explicit PR ID to inspect a completed PR.

Set the per-repository remote with `git config --local azure-devops.remote <name>`;
the default remains `origin`. The selected remote must have one fetch URL and one
push URL for the same repository. `ado-rest context` shows the safe, parsed
organization/project/repository and verifies the matching authentication profile.

### `pr-status`

Shows CI/build status for the current branch's PR, and drills into the failing job's log if it's red.

```sh
pr-status             # auto-detects PR from current branch
pr-status <PR_ID>     # specific PR
pr-status --watch     # re-check every 20s until no longer pending
```

Same auth and org resolution as `pr`. **Requires:** `jq`, `curl`

HTTP, connection, and malformed-response failures exit non-zero. A failed policy
request is not treated as an empty set of checks. `--interval` requires a positive
integer number of seconds.

### `repo`

Looks up an open PR for the current branch and opens it in Chrome when authentication and lookup dependencies are available; otherwise opens the repository page. Supports Azure DevOps and GitHub remotes.

```sh
repo
```

Supports SSH and HTTPS remotes, including legacy Azure DevOps `visualstudio.com` URLs.

### `submit-pr`

Creates an Azure DevOps PR from the current branch and links it to a ClickUp task.

```sh
submit-pr              # auto-detects ClickUp task ID from branch name
submit-pr 86abc123    # explicit task ID
```

The script will:
1. Extract the ClickUp task ID from your branch name (e.g. `feat/#86abc123-add-login`)
2. Fetch the task title from ClickUp to use as the PR title
3. Push the branch and create a PR with `closes https://www.clickup.com/t/{taskId}` in the description
4. Add the PR URL as a comment on the ClickUp task
5. Prompt you to update the ClickUp task status

**Auth:** Azure DevOps uses the selected repository profile or the legacy
single-org `AZURE_DEVOPS_ORG` plus `AZURE_DEVOPS_PAT` pair (same as `pr`). Azure
CLI auth must use a profile pinned to its tenant, account name, and user object ID.
- ClickUp: `CLICKUP_API_TOKEN` in `alias/.env` or exported (generate at ClickUp → Settings → Apps)

Without `CLICKUP_API_TOKEN`, the script still creates the PR but skips ClickUp integration.

API requests in the PR utilities use a 10-second connection timeout and a
60-second total timeout. HTTP errors and malformed JSON are reported without
printing response bodies or credentials. Mutations are not retried automatically.
`repo` retains its repository-page fallback when optional PR lookup fails;
`submit-pr` can continue after an optional ClickUp request fails.

**Requires:** `jq`, `curl`

### `config-git`

Sets local `user.name` and `user.email` for the current Git repository using `GIT_WORK_NAME` and `GIT_WORK_EMAIL`. Configure both in the ignored `alias/.env` file, or export them in your shell. The script loads missing values from the repository's `alias/.env` and changes only the current repository's local Git config.

```sh
config-git
```

### `local-env`

A file to be **sourced** (Bash or Zsh), not executed. It loads named values from `alias/.env` into the current shell as plain, non-exported variables, for agent skills and one-off snippets that need a token the interactive shell no longer exports.

```sh
source "$(command -v local-env)" CLICKUP_API_TOKEN
```

It prints nothing, and there is no mode that prints a value; executing it only explains that it must be sourced. A value that is already exported and non-empty wins and is left as it was. A name `alias/.env` does not define stays unset, so test the variable afterwards.

Exposure that remains: the variable exists in that shell, so anything that echoes it, runs under `set -x`, or exports it can reveal it, and a command line that carries it (such as `curl -H "Authorization: $TOKEN"`) is visible in the process's arguments while it runs.

### `docker-clean`

Lists every container known to the current Docker daemon (ID, name, and status), including stopped containers, then asks for confirmation before stopping and removing them. Only `y` or `yes` (case-insensitive) confirms; any other answer or end of input cancels. Check the target daemon before running it.

```sh
docker-clean        # preview containers and confirm before removal
docker-clean --yes  # skip confirmation (-y also works)
```

Requires the Docker CLI and a running Docker daemon.

### `sync-branch`

Fetches and prunes `origin`, then considers only local branches whose configured upstream refs are gone. A gone upstream alone does not prove a merge (the branch may have been abandoned), and squash or rebase merges never put the branch's commits into the base history. Normal mode therefore deletes a branch only when one of these holds against an existing `origin/main`, `origin/master`, or `origin/develop` ref, checked in this order:

1. The branch tip is contained in the base history.
2. For an Azure DevOps `origin`, a completed PR from that branch into the base was merged at exactly the branch's current tip (looked up with `ado-rest`). Commits added after the merge keep the branch.
3. Merging the branch into the base changes nothing, so every change is already present in its content. A later edit to the same lines on the base makes this fail and keeps the branch.

Branches that none of these confirm are preserved. If the PR lookup fails (no profile, offline), the run says so and falls back to the content check. Branches checked out in any worktree are never deleted. Local `main`, `master`, and `develop` branches are protected. The content check needs Git 2.38 or newer; older Git keeps the branch.

```sh
sync-branch                 # delete only confirmed-merged stale branches
sync-branch --dry-run       # preview the default actions
sync-branch --force         # may delete unmerged stale local commits
sync-branch --dry-run --force  # preview force-mode actions
```

`--dry-run` still fetches and prunes refs but does not delete branches. Use `--force` only when you intend to delete stale branches with commits not confirmed in a surviving primary branch; worktree protection still applies.

After the summary, it prints the resulting branch list (local branches with their upstream and ahead/behind state, then remote-tracking branches), so a separate `git branch -a` is not needed. Under `--dry-run` the list shows the unchanged current state. Output is colored only when writing to a terminal; set `NO_COLOR=1` to disable it.

### `morning`

Start-of-day sync for the repositories you work in. List them in `alias/.env`:

```sh
export MORNING_REPOS="$HOME/code/project-a:$HOME/code/project-b"   # colon-separated; "~" works
```

The work notes checkout is added automatically when present. For each repository, `morning`:

1. Fetches `origin` and fast-forwards the default branch when it is checked out with no local changes and no local-only commits. A repository on another branch, with uncommitted changes, or with unpushed commits is reported and left alone.
2. If `orca` is installed, lists Orca worktrees whose upstream branch is gone. One whose changes are already on the default branch (same proof as `sync-branch`), with no uncommitted changes and no open Orca terminal, is shown with the `orca worktree rm` command that removes it; others are flagged for a manual check. `morning` never removes worktrees.
3. Runs `sync-branch` to delete local branches proven merged. Branches still held by a worktree are kept, so run `morning` again after removing worktrees.

```sh
morning              # sync, review worktrees, clean merged branches
morning --dry-run    # fetch only; report what would change
```

Missing configuration and unusable paths are warnings: `morning`, `install.sh`, and `doctor` each report an unset `MORNING_REPOS` and any listed path that is missing, not a Git repository, or has no `origin` remote.

### `track-branch`

Fetches `origin` and prunes stale refs, then creates or configures a local tracking branch for an existing remote branch. It does not check out or switch branches. With no argument, it offers interactive selection using `fzf` or a numbered Bash menu; `main`, `master`, and `develop` are hidden. A branch already checked out in any worktree cannot be prepared for reuse.

```sh
track-branch feature/foo
track-branch origin/feature/foo
track-branch
```

Use `track-branch` to prepare a remote branch for reuse; `sync-branch` separately cleans up stale-upstream local branches while preserving unconfirmed work by default.

### `bookmark`

Saves a `cd` alias for the current directory into `.user_alias`.

```sh
cd /path/to/project
bookmark
# Enter an alias name, e.g. "myproject"
# Adds a safely quoted alias for this directory
```

Directory names containing quotes, dollar signs, backticks, or newlines are
escaped both when loading the alias file and when running the alias.

### `gen-tax-id`

Generates a valid Taiwan 統一編號 (Unified Business Number).

```sh
gen-tax-id          # generate one number
gen-tax-id -n 5     # generate five numbers
```

The checksum is computed deterministically from the first 7 digits so the output is always valid — no rejection sampling needed.

### `image-shrink`

Resize and compress a local JPEG, PNG, WebP, or HEIC/HEIF image to a maximum
file size. Requires ImageMagick (`brew install imagemagick`); Homebrew includes
`libheif` for iPhone photos. All processing stays on your machine.

```sh
image-shrink photo.jpg                                  # default: at most 500 KB
image-shrink photo.jpg --max-size 0.5MB                  # 500,000 bytes
image-shrink photo.jpg --max-size 500KB --max-side 1600   # longest edge at most 1600
image-shrink photo.jpg --max-size 500KB --keep-dimensions # compression only
image-shrink IMG_1234.HEIC --max-size 500KB               # keep HEIC format
image-shrink IMG_1234.HEIC --format jpg -o share.jpg      # convert for sharing
image-shrink screenshot.png --format webp               # explicit conversion
image-shrink                                           # prompts; also available in cmds
```

With no arguments in a terminal, prompts ask for an image path, maximum file size
(default `500KB`), optional maximum longest edge, and output format (default: same).
When `fzf` is installed, an image picker opens in the current directory. Type to
filter the supported images and directories; use **Up/Down** or **Tab/Shift-Tab**
to move, then **Enter** to select an image or open a directory. Select `../` to go
up a directory, or **Esc** to cancel before processing anything. Hidden entries
are included. Files without a supported image extension are omitted.

Choose `[Enter a path]` to paste an unquoted path elsewhere. Without `fzf`, this
path prompt opens directly: **Tab** completes paths and lists ambiguous matches.
Filename completion handles spaces and backslashes; entered shell expressions
are never evaluated. The picker also works through `cmds`. `fzf` is optional and
already included in `Brewfile` (`brew install fzf`).

With arguments, the command never prompts; quote paths containing spaces in shell
commands. Use `--` before a filename beginning with a dash.

The default output is a sibling such as `photo.small.jpg` or `IMG_1234.small.heic`.
The original is retained and existing output files, directories, and symlinks are
never replaced. `-o` selects another output path; its extension selects the format
and must agree with `--format` if both are supplied. The output directory must
already exist and support hard links; a private working directory there is removed
on completion or interruption, and a verified result is published atomically.

`KB`/`MB` use decimal units; `KiB`/`MiB` use binary units. Sizes can be fractional
and are rounded down to whole bytes (accepted range: 1 byte to 1 TB). The tool
reports exact before/after byte counts and dimensions. It skips an image already
under the limit unless a resize, format, or output path is explicitly requested.

For JPEG, WebP, and HEIC, it first tries encoder quality 90, then searches down to
60 at the current dimensions. If needed, it progressively reduces dimensions,
preserving proportions and never enlarging. PNG uses lossless compression at each
resolution; smaller PNG targets can require a resize or an explicit conversion to
WebP. Every attempt derives from the same lossless, oriented working image rather
than a previously compressed result. Color profiles are retained.

Automatic resizing stops at a 320-pixel longest edge, or the starting edge if
smaller. An explicit `--max-side` below 320 is respected; values from 1 to 100000
are accepted. `--keep-dimensions` prevents all resizing and cannot be combined
with `--max-side`. If the target cannot be met within these bounds, the command
fails without publishing an oversized output. A size limit may require visible
loss of detail; encoder quality is not a guarantee of perceived quality.

Orientation is applied before resizing. Transparency is retained for supported
formats; conversion of a transparent image to JPEG is rejected. Only the primary
still image is processed, including for HEIC and animated inputs. Output does not
promise to retain Live Photo video, auxiliary depth data, or HDR gain maps. The
command checks that the installed ImageMagick supports the requested codecs;
`doctor` also checks HEIC reading and writing.

### `cmds`

Interactive menu to browse and run any script in the `scripts/` directory.

```sh
cmds
```

Uses `fzf` when available; otherwise it provides an arrow-key Bash menu. `fzf` is optional (`brew install fzf`).
The Bash menu restores terminal settings and the cursor before launching a script,
and on cancellation or interruption.

## Dependencies

`Brewfile` holds two categories of packages:

1. **Dotfiles dependencies**, used directly by the scripts and shell behavior: `git-delta`, `fzf`, `jq`, `azure-cli`, `gh`, `python`, `starship`, `shellcheck`, `imagemagick`, and the Hack Nerd Font cask. The table below lists what uses each one.
2. **Workstation baseline**, standard tools wanted on every development Mac that the repository does not itself invoke: `gawk` and `pyenv`. They are installed for convenience and have no "Required by" entry. The shared zsh configuration does not initialise pyenv; see [Design decisions](#design-decisions) to enable it.

`./install.sh --install-deps` installs only the missing packages and leaves installed ones as they are. `doctor` checks the tools in the table that affect dotfiles functionality and reports the ones still missing; it does not check the baseline packages. Install Homebrew first (https://brew.sh). Docker is not included. oh-my-zsh is not a Homebrew package; `--install-deps` clones it separately.

| Tool | Required by | Install |
|------|-------------|---------|
| `delta` | git diff pager | `brew install git-delta` |
| `fzf` | `cmds`, `track-branch`, `image-shrink` picker (optional; all have Bash fallbacks); shell key bindings in `zsh/.zshrc.shared` (0.48+, optional) | `brew install fzf` |
| `jq` | `pr`, `pr-comments`, `pr-status`, `submit-pr`, `ado-rest`; optional PR lookup in `repo` | `brew install jq` |
| `curl` | `pr`, `pr-comments`, `pr-status`, `submit-pr`, `ado-rest`; optional PR lookup in `repo` | usually pre-installed |
| `az` | Azure DevOps profiles configured with `auth = azure-cli` | `brew install azure-cli` |
| `gh` | GitHub mode of `create-pr`; optional GitHub auth for `repo` | `brew install gh` |
| `starship` | shared prompt (`zsh/starship.toml`); needs a Nerd Font, falls back to the oh-my-zsh theme without it | `brew install starship` |
| `shellcheck` | lint of `install.sh`, `scripts/*`, `lib/*.sh`, and `tests/*.sh` in CI and before committing shell changes (see `AGENTS.md`) | `brew install shellcheck` |
| `magick` | `image-shrink`; includes `libheif` for HEIC/HEIF input and output | `brew install imagemagick` |
| Nerd Font | starship prompt icons; without one (or without selecting it in the terminal profile) icons render as boxes | `brew install --cask font-hack-nerd-font`, then pick **Hack Nerd Font** in the terminal's font setting |
| `python3` | `server` alias; regression test suites | `brew install python` |
| Docker CLI and running daemon | `docker-clean` (includes stopped containers) | Docker Desktop or another Docker daemon |

## Git Config

`.gitconfig` is symlinked to `~/.gitconfig`. Highlights:

- **Pager:** `delta` with side-by-side diffs; the light or dark theme is auto-detected from the terminal
- **Merge conflicts:** `zdiff3` style
- **Shared defaults:** see [Shared defaults](#shared-defaults) below
- **Global gitignore:** `git/.gitignore_global`
- **Identity:** not tracked. `.gitconfig` ends with `[include] path = ~/.gitconfig.local`, and `install.sh` creates that file from `git/.gitconfig.local.example`. Edit it to set `user.name` and `user.email`; `doctor` warns while either is missing.

### Shared defaults

`.gitconfig` sets these identity-free defaults on every machine:

| Setting | Value | Effect |
| --- | --- | --- |
| `init.defaultBranch` | `main` | New repositories start on `main` |
| `push.autoSetupRemote` | `true` | The first `git push` of a new branch sets its upstream |
| `fetch.prune` | `true` | Fetching drops remote-tracking refs deleted on the remote |
| `pull.rebase` | `true` | `git pull` (and the `gl` alias) rebases local commits instead of creating merge commits |
| `rebase.autoStash` | `true` | Rebasing with a dirty working tree stashes and restores it |
| `rebase.updateRefs` | `true` | Rebasing a stack of branches moves the intermediate branches too (Git 2.38+) |
| `rerere.enabled` | `true` | Git remembers and reuses conflict resolutions |
| `diff.algorithm` | `histogram` | Clearer diffs than the default algorithm |
| `diff.colorMoved` | `default` | Moved lines are colored differently from added and removed ones |
| `branch.sort` | `-committerdate` | `git branch` lists the most recently committed branches first |

Settings your Git version does not know are ignored, so older Git releases still work.

To override a default on one machine, set it in `~/.gitconfig.local`. It is included last, so it wins:

```ini
[pull]
	rebase = false
[delta]
	dark = true
```

### Separate work identity (Azure DevOps)

To commit to Azure DevOps repositories with a different identity than your personal GitHub one:

1. Keep your personal identity in `~/.gitconfig.local` (the default for every repository).
2. Put the work identity in `~/.gitconfig.work`, which `install.sh` creates from `git/.gitconfig.work.example`.
3. In `~/.gitconfig.local`, set the organization name in the matching `includeIf` rules from `git/.gitconfig.local.example`.

Edit the example rules to use your **work organization name**. The example patterns match that organization over HTTPS, SSH, and legacy `visualstudio.com`; personal Azure DevOps repositories keep the default identity. This needs Git 2.36 or newer and a remote that is already set, so a fresh `git init` uses the default identity until you add the remote. Check a repository with `git config user.email`. `doctor` warns when the rules are enabled but `~/.gitconfig.work` is missing.

`config-git` still works as a per-repository override: it writes `GIT_WORK_NAME` and `GIT_WORK_EMAIL` from `alias/.env` into that repository's local config, which takes precedence over both files.

On a laptop that already used the old tracked identity, create `~/.gitconfig.local` with your `[user]` section (or run `install.sh` and fill in the template) after pulling; otherwise commits fail with an unknown identity.

## Tokens & Local Configuration

Some scripts/skills talk to external APIs (ClickUp, Azure DevOps) and need a token. `install.sh` creates `alias/.env` from `alias/.env.example` — a per-machine, gitignored file — the first time you run it. Open it and uncomment/fill in the values you need.

Keep these separate: **Git commit identity** is `user.name`/`user.email`; **Git transport authentication** is an SSH key or Git credential helper; **Azure CLI authentication** is the account already signed in to `az`; **Azure DevOps REST authentication** is selected per organization below. The repository never switches your Azure CLI account or subscription.

### Azure DevOps work and personal accounts

Store non-secret profile routing in `~/.gitconfig.local` and PATs in `alias/.env`.
Create a uniquely named profile and matching PAT variable for each organization.
The example below configures two company organizations and a personal organization;
add more profiles as needed:

```ini
[azure-devops "work-company-a"]
	organization = company-a
	auth = pat
[azure-devops "work-company-b"]
	organization = company-b
	auth = pat
[azure-devops "personal"]
	organization = personal-org
	auth = pat
```

These are placeholder organizations and profile labels. Store each PAT under its
matching variable in your local `alias/.env`; keep credential values out of Git,
command arguments, and agent conversations.

| Repository profile | Organization placeholder | PAT variable |
|--------------------|--------------------------|--------------|
| `work-company-a` | `company-a` | `AZURE_DEVOPS_PAT_WORK_COMPANY_A` |
| `work-company-b` | `company-b` | `AZURE_DEVOPS_PAT_WORK_COMPANY_B` |
| `personal` | `personal-org` | `AZURE_DEVOPS_PAT_PERSONAL` |

Select exactly one profile in each repository. For a repository in `company-a`:

```sh
git config --local azure-devops.profile work-company-a
```

Select `work-company-b` in a repository in `company-b`, and `personal` in a personal
repository. The remote determines the organization, project, and repository, but
does not automatically select an authentication profile. A profile whose configured
organization does not match the remote is rejected before authentication or a
request; commands do not try another profile on failure. If the repository uses a
remote other than `origin`, select it with `git config --local azure-devops.remote <name>`.
Fetch and push URLs must resolve to the same provider and repository. Custom SSH
host aliases need a Git `url.*.insteadOf` rule that resolves to a canonical host.

Profile names start with a lowercase letter and contain only lowercase letters,
digits, or hyphens. Underscores are rejected so each profile maps to a distinct PAT
variable name.

For `pr` outside a repository, set `AZURE_DEVOPS_PROFILE=work-company-a` (or another
configured profile) in `alias/.env`. The profile supplies its organization. A legacy single-org setup can
keep `AZURE_DEVOPS_ORG` and `AZURE_DEVOPS_PAT`, but the organization must match the
repository remote; the override is never allowed to redirect a repository command.

Azure CLI profiles use `auth = azure-cli` plus `tenant`, `user`, and `object-id`
fields in `~/.gitconfig.local`. `ado-rest` verifies the active account name, tenant,
and the Azure DevOps token's tenant/object ID before sending a request. Obtain the
non-secret account metadata only if you need it for profile setup:

```sh
az account show --query '{tenantId:tenantId,user:user.name}' --output json
az ad signed-in-user show --query id --output tsv
```

If the tenant, user, or object ID cannot be verified, use a per-organization PAT profile.
Never run `az account set` to make a PR command work.

For PAT authentication, `ado-rest context` checks the repository/profile binding
and local credential availability; it does not contact Azure DevOps to validate
the PAT. A successful read-only GET is needed to confirm that Azure DevOps accepts
the PAT and authorizes that endpoint. Validate each organization separately using
its intended repository, profile, and authorized device. Successful PAT reads do
not establish write permissions, validate agent-initiated PR creation/update or
Azure CLI profiles, or constitute a broader authorization/security assessment.

**`alias/.env` is not sourced by your shell.** Exporting tokens from every interactive shell would hand them to every child process: npm/yarn lifecycle scripts, editors, language servers, and coding agents. Instead each script loads only the names it needs, when it runs, through `lib/local-env.sh`:

- Values already exported in your environment take precedence over `alias/.env`, so an environment-provided `AZURE_DEVOPS_PAT_WORK_COMPANY_A` works as a one-off override for the selected profile. Profile hyphens map to underscores in the PAT variable name.
- Loaded values are plain shell variables inside the script, not exported, so `git`, `az`, and `curl` do not inherit them. This holds even if the caller had exported an empty variable of that name.
- Azure DevOps REST requests pass the selected authorization header through a private pipe using an inherited file descriptor. No header file is created, so interrupted requests leave no credential file behind. The value is not placed in curl's argument list, and caller stdin and signal handlers are preserved.
- Agent skills use `ado-rest` for Azure DevOps API requests and `source "$(command -v local-env)" CLICKUP_API_TOKEN` for ClickUp snippets. Every Bash tool call is a fresh shell; the loader sets a non-exported value and prints nothing. See [`local-env`](#local-env) for what remains exposed.

Migration: if you relied on `alias/.env` to export other variables into your shell (for example a `PATH` entry or `JAVA_HOME`), move them to `alias/.user_alias` or `zsh/.zshrc.local`. To confirm a new shell exports no tokens, list names only, never values: `env | cut -d= -f1 | grep -xE 'CLICKUP_API_TOKEN|AZURE_DEVOPS_PAT|AZURE_DEVOPS_ORG|GITHUB_TOKEN|GIT_WORK_NAME|GIT_WORK_EMAIL'` should print nothing. Do not run `env`, `printenv`, or `echo "$TOKEN"` where the output is logged or captured by an agent.

| Variable | Used by | Required? |
|-------|---------|-----------|
| `CLICKUP_API_TOKEN` | `submit-pr`, `create-clickup-task`, Azure DevOps mode of `create-pr` | No — ClickUp integration is skipped if unset |
| `AZURE_DEVOPS_PAT_<PROFILE>` | Azure DevOps REST calls for the selected Git config profile; for example `AZURE_DEVOPS_PAT_WORK_COMPANY_A` | Required for a `pat` profile |
| `AZURE_DEVOPS_PAT` | Legacy single-organization REST setup | No — use only with matching `AZURE_DEVOPS_ORG` |
| `AZURE_DEVOPS_ORG` | Legacy single-org setup; explicit organization for `pr` outside a repository | No — must match a repository remote and never overrides it |
| `AZURE_DEVOPS_PROFILE` | `pr` outside a repository | No — selects a profile whose organization is configured in Git config |
| `GITHUB_TOKEN` | Optional GitHub PR lookup in `repo` | No — `repo` falls back to `gh auth token` |
| `GIT_WORK_NAME` | `config-git` | Needed with `GIT_WORK_EMAIL` when configuring a repository |
| `GIT_WORK_EMAIL` | `config-git` | Needed with `GIT_WORK_NAME` when configuring a repository |

GitHub mode of `create-pr` uses `gh`, which authenticates through `gh auth login` or its own `GH_TOKEN`/`GITHUB_TOKEN` environment variables; it does not read `alias/.env`.

Run `doctor` to check whether the ClickUp token and optional work Git identity are configured; it never prints their values. `config-git` applies the identity only to the current repository.

The installer preserves existing `.env` files and their permissions. `doctor`
warns if group or other users have access; use `chmod 600 ~/dotfiles/alias/.env`
to restrict the file to its owner.

## Verification

Run syntax, ShellCheck, whitespace, and regression checks locally:

```sh
for file in install.sh scripts/* lib/*.sh tests/*.sh; do /bin/bash -n "$file" || exit 1; done
for file in alias/.alias alias/.git_alias alias/.util_alias zsh/.zshrc.shared; do zsh -n "$file" || exit 1; done
shellcheck -S warning -x install.sh scripts/* lib/*.sh tests/*.sh
git diff --check
for file in tests/*.sh; do /bin/bash "$file" || exit 1; done
```

The regression suites require Git, `jq`, Zsh, Python 3, ImageMagick (with HEIC support), `fzf`, and Ruby (preinstalled on macOS; the CI workflow test parses YAML with it). They use temporary
homes and repositories, API/push shims, and a pseudo-terminal; they do not perform
real PR mutations or migrations against your home directory. Coverage includes
installer idempotency and skill migration, diagnostic accuracy, API failures,
branch preservation, bookmark quoting, menu cleanup, the behind-origin check,
and image size limits, format conversion, transparency, orientation, and output preservation.

GitHub Actions runs these checks on macOS for pushes to `master` and for pull requests targeting `master`, so a commit on a PR branch is checked once. A newer push to a PR cancels that PR's superseded run; `master` runs are never cancelled.

## Adding Your Own Aliases

Edit `alias/.user_alias` directly, or use the `bookmark` script for directory shortcuts:

```sh
# alias/.user_alias
alias myproject="cd ~/projects/myproject"
alias myserver="ssh user@192.168.1.100"
```

## License

Released under the [MIT License](LICENSE). `skills/skill-creator` is a third-party skill distributed under the Apache License 2.0; see `skills/skill-creator/LICENSE.txt`.
