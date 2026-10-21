---
name: fix-npm-audit
description: 'Run `npm audit`, plan fixes by severity level, ask the user before applying, then commit.'
argument-hint: '<severity level: critical | high | moderate | low | all>'
---

# Fix npm Audit Issues

## When to Use

When you need to review and fix npm dependency vulnerabilities reported by `npm audit`. This skill plans before acting — it shows you what will change and asks for approval before applying fixes.

## Procedure

### 1. Parse the severity argument

The user provides a severity level as the skill argument:

| Argument   | What gets fixed                |
| ---------- | ------------------------------ |
| `critical` | Only critical vulnerabilities  |
| `high`     | Critical + high                |
| `moderate` | Critical + high + moderate     |
| `low`      | All severities (same as `all`) |
| `all`      | All severities                 |

If no argument is provided, **ask the user** which level to address using `ask_user`:

```
Which severity level should I address?
Choices: ["critical", "high", "moderate (Recommended)", "all"]
```

### 2. Run the audit report

```bash
npm audit --json 2>&1
```

Parse the JSON output to build a summary table of vulnerabilities at or above the chosen severity level. Group by package name and include:

- **Package** — the vulnerable dependency
- **Severity** — critical / high / moderate / low
- **Via** — which direct dependency pulls it in (direct vs transitive)
- **Fix available** — whether `npm audit fix` can resolve it
- **Fix type** — what kind of version bump is needed:
  - **patch** — bugfix bump (e.g., 1.0.0 → 1.0.1) — safe
  - **minor** — minor bump (e.g., 1.0.0 → 1.1.0) — usually safe
  - **major / breaking** — major bump (e.g., 1.x → 2.x) — requires `--force`, may break things
  - **no fix** — no patched version available yet

### 3. Present the plan and ask for approval

Show the user a summary like:

```
## npm Audit Fix Plan (severity ≥ high)

| Package       | Severity | Fix Type | Version Change     |
| ------------- | -------- | -------- | ------------------ |
| lodash        | critical | patch    | 4.17.20 → 4.17.21  |
| axios         | high     | minor    | 0.21.1 → 0.27.2    |
| webpack-dev   | high     | major    | 3.x → 5.x          |
| node-forge    | high     | no fix   | —                   |

### Safe fixes (patch/minor): 2 packages
### Breaking fixes (major): 1 package — requires --force
### No fix available: 1 package — must wait for upstream
```

Then ask the user what to do using `ask_user`:

```
How should I proceed?
Choices:
- "Apply safe fixes only (patch + minor)"
- "Apply all fixes including breaking changes (--force)"
- "Skip — don't fix anything"
```

### 4. Apply the chosen fixes

Based on the user's choice:

**Safe fixes only:**

```bash
npm audit fix 2>&1
```

**All fixes including breaking:**

```bash
npm audit fix --force 2>&1
```

### 5. Verify after fixing

After applying fixes, run the full verification:

```bash
npm audit 2>&1                    # confirm remaining vulnerabilities
npm run lint 2>&1                 # ensure no lint regressions
npm run typecheck 2>&1            # ensure no type regressions
npm run test 2>&1                 # ensure no test regressions
```

If any check fails, investigate and fix the regression before committing. Common issues after `--force`:

- Breaking API changes in upgraded packages
- Peer dependency conflicts
- Removed/renamed exports

### 6. Commit the fixes

```bash
git add -A
git commit -m "fix: resolve npm audit vulnerabilities

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

If breaking changes were applied and required code changes, consider splitting into two commits:

1. `chore: bump vulnerable dependencies`
2. `fix: adapt code to breaking dependency changes`
