---
name: research-prompt
description: 'Write a prompt for another agent to investigate a codebase read-only, such as a backend or legacy repository the lead cannot read. Use when delegating source research or requesting evidence for a cross-repository decision.'
---

# Read-only research prompt

Use this skill to write a prompt for an investigator in another codebase. Choose the tool, model and effort using the user's routing guide when available; always pass effort explicitly. Never ask the investigator to edit, run or deploy anything.

Give background on what the frontend or caller does, then number questions that source code can answer. Separate what exists from what should change; ask for the smallest change that would address the need, without implementing it. Require each answer to cite `file:line` and mark it `confirmed from code` or `inferred`. Where code cannot answer, require whom to ask and the exact question. Require checkout freshness: whether it is a Git checkout, its last commit or file mtime, and whether it matches the deployed version (or explicitly unknown). Require read-only inspection and no credential files.

After receiving the answer, spot-check two or three citations when accessible. Never trust unverified file sizes or numbers; compare surprising claims against known facts and check the arithmetic. If the lead cannot access the cited source, report that the citations could not be independently checked.

## Template

```text
Investigate <codebase> read-only. Do not edit, run or deploy anything, and do not read credential files.

Background: <what the frontend or caller does and why the answer is needed>.

1. What exists: <source-answerable question>?
2. What exists: <source-answerable question>?
3. What should change: what is the smallest change to address <need>? Do not implement it.

For each answer cite file:line and mark it confirmed from code or inferred. If code cannot answer, state whom to ask and the exact question. Report whether this is a Git checkout, its last commit or file mtime, and whether it matches the deployed version; say unknown if that cannot be established read-only.
```
