---
name: implement-spec
description: Implement a spec while maintaining a running implementation-notes.html that captures design decisions, deviations, tradeoffs, and open questions. Use when the user wants to build something from a spec or requirements document.
argument-hint: "Path or description of the spec to implement"
---

# Implement Spec

## When to Use

When the user wants to implement a spec, requirements document, PRD, or design document. Trigger phrases: "implement this spec", "build this from the spec", "implement <SPEC>", "implement according to spec".

## Procedure

### 1. Read the spec

If the user passed an argument pointing to a file, read it. If they pasted the spec inline, use that. If neither, ask the user to provide the spec before proceeding.

Identify:
- What is being built
- Explicit requirements (must-haves)
- Implicit requirements (things the spec assumes without stating)
- Ambiguities that will require a decision

### 2. Create implementation-notes.html

Before writing any code, create `implementation-notes.html` in the project root. Initialise it with the structure below — it will be updated throughout the implementation.

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Implementation Notes</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 860px; margin: 2rem auto; padding: 0 1rem; color: #1a1a1a; }
    h1 { font-size: 1.5rem; border-bottom: 2px solid #e5e5e5; padding-bottom: 0.5rem; }
    h2 { font-size: 1.1rem; margin-top: 2rem; color: #444; }
    table { width: 100%; border-collapse: collapse; margin-top: 0.75rem; font-size: 0.9rem; }
    th { text-align: left; background: #f5f5f5; padding: 0.5rem 0.75rem; border: 1px solid #ddd; }
    td { padding: 0.5rem 0.75rem; border: 1px solid #ddd; vertical-align: top; }
    tr:nth-child(even) td { background: #fafafa; }
    .tag { display: inline-block; padding: 0.15rem 0.4rem; border-radius: 3px; font-size: 0.75rem; font-weight: 600; }
    .tag-decision { background: #dbeafe; color: #1d4ed8; }
    .tag-deviation { background: #fce7f3; color: #9d174d; }
    .tag-tradeoff { background: #fef3c7; color: #92400e; }
    .tag-open { background: #dcfce7; color: #166534; }
    .updated { font-size: 0.75rem; color: #888; margin-top: 0.5rem; }
  </style>
</head>
<body>
  <h1>Implementation Notes</h1>
  <p class="updated">Last updated: <span id="ts">—</span></p>
  <script>document.getElementById('ts').textContent = new Date().toLocaleString();</script>

  <h2>Design Decisions</h2>
  <p>Choices made where the spec was ambiguous.</p>
  <table id="decisions">
    <tr><th>Area</th><th>Decision</th><th>Rationale</th></tr>
  </table>

  <h2>Deviations</h2>
  <p>Places where the implementation intentionally departs from the spec.</p>
  <table id="deviations">
    <tr><th>Spec says</th><th>What was built instead</th><th>Why</th></tr>
  </table>

  <h2>Tradeoffs</h2>
  <p>Alternatives considered and why the chosen approach was picked.</p>
  <table id="tradeoffs">
    <tr><th>Area</th><th>Chosen approach</th><th>Alternatives considered</th><th>Why this one</th></tr>
  </table>

  <h2>Open Questions</h2>
  <p>Things to confirm or revise.</p>
  <table id="open">
    <tr><th>Question</th><th>Context</th><th>Impact if wrong</th></tr>
  </table>
</body>
</html>
```

### 3. Implement incrementally

Work through the spec section by section. After completing each logical unit of work (a feature, a module, a route, etc.):

1. **Update implementation-notes.html** — add any new rows to the relevant tables before moving to the next unit. Never batch notes for the end; keep the file current as you go.
2. **Keep entries honest** — if you made a call the user might disagree with, say so plainly in the rationale. The notes are for the user, not for posterity.

### 4. What belongs in each section

**Design Decisions** — the spec left something underspecified and you had to pick. Examples:
- Field naming convention the spec didn't define
- Pagination strategy not mentioned
- Which HTTP status code to use for a specific error

**Deviations** — you chose to do something differently from what the spec says, intentionally. Examples:
- Spec says use localStorage, you used a cookie because of XSS risk
- Spec requires a polling interval, you used a websocket instead

**Tradeoffs** — you had two or more reasonable options and had to pick one. Examples:
- Chose eager loading over lazy loading for this relationship
- Chose to colocate validation with the model rather than a separate layer

**Open Questions** — you made a call but aren't confident, or the spec has a gap that could bite the user later. Examples:
- "The spec doesn't say whether deleted records should be soft-deleted — I used hard delete. Confirm?"
- "Rate limiting isn't specced — I didn't add it. Should it be?"

### 5. Finish and summarise

When the implementation is complete, do a final pass over implementation-notes.html:

- Promote any open questions that were resolved during implementation to the appropriate section
- Remove any notes that turned out to be irrelevant
- Add a brief summary paragraph at the top of the file describing what was built

Then tell the user:

```
Implementation complete. Open implementation-notes.html to review decisions, deviations, tradeoffs, and any open questions I flagged for you.
```
