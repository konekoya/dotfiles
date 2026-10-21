---
name: fix-npm-vet
description: 'Run `npm run vet` (lint, typecheck, format, test), fix every reported issue, and commit the result.'
---

# Fix Vet Issues

## When to Use

When you need to run the full local quality gate (`npm run vet`) and fix all reported issues before committing. Typically used after a batch of changes or before pushing a branch.

## What `npm run vet` Checks

`vet` runs four checks concurrently:

| Check            | Script                 | What it does                          |
| ---------------- | ---------------------- | ------------------------------------- |
| **Lint**         | `npm run lint`         | `nx affected:lint` — ESLint           |
| **Type check**   | `npm run typecheck`    | `nx run-many --target=typecheck` — TS |
| **Format check** | `npm run format:check` | Prettier diff check                   |
| **Test**         | `npm run test`         | `nx run-many --target=test` — Vitest  |

## Procedure

### 1. Run the individual checks separately (not `npm run vet`)

Running all four concurrently mixes output and makes failures hard to parse. Instead, run them one at a time and capture output:

```bash
npm run lint 2>&1
npm run typecheck 2>&1
npm run format 2>&1          # format:write auto-fixes formatting
npm run test 2>&1
```

> **Tip:** Run `npm run format` (write mode) instead of `format:check` — it auto-fixes formatting issues so you don't have to.

### 2. Fix issues in priority order

Fix in this order because later checks depend on earlier ones:

1. **Format** — already auto-fixed by `npm run format`.
2. **Lint errors** — fix code issues reported by ESLint. Use `--fix` where safe:
   ```bash
   npx nx affected:lint --fix 2>&1
   ```
   Then fix remaining issues manually.
3. **Type errors** — fix TypeScript compilation errors.
4. **Test failures** — fix or update failing tests.

### 3. Re-run to confirm all clean

After fixing, run each check again to confirm zero issues:

```bash
npm run lint 2>&1
npm run typecheck 2>&1
npm run format:check 2>&1
npm run test 2>&1
```

All four must pass before proceeding.

### 4. Commit the fixes

Stage and commit all changes:

```bash
git add -A
git commit -m "fix: resolve vet issues

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

If the fixes span multiple unrelated areas, consider splitting into separate commits (e.g., one for lint fixes, one for test fixes).
