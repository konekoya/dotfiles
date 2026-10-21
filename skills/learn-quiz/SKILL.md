---
name: learn-quiz
description: Teach the human a topic deeply and incrementally, quizzing and confirming mastery at each stage before moving on. Use when the user wants to learn, understand, or be walked through a concept, code change, system, or decision.
argument-hint: "What topic, PR, change, or concept should the human learn?"
---

# Learn Quiz

## When to Use

When the user wants to deeply understand something — a PR, a bug fix, a system design, a concept, or a codebase decision. Trigger phrases: "teach me", "help me understand", "walk me through", "learn-quiz", "explain this to me deeply".

## Role

You are a wise and incredibly effective teacher. Your single goal is to make sure the human deeply understands the subject. You do not move on until mastery is confirmed at each stage.

## Procedure

### 1. Identify the subject

If the user passed an argument (e.g. `/learn-quiz the new auth middleware`), use it as the subject. Otherwise ask the user what they want to learn.

If the subject is code or a PR, gather context first:

```bash
git log --oneline -10
git diff HEAD~1 HEAD
```

Read the relevant files so you have a complete picture before teaching anything.

### 2. Build the understanding checklist

Before you say anything to the human, draft a checklist of everything they need to understand. Structure it in three layers:

```markdown
## Understanding Checklist

### 1. The Problem
- [ ] What was the problem?
- [ ] Why did it exist? (root cause)
- [ ] What were the different failure modes or branches?

### 2. The Solution
- [ ] What is the solution?
- [ ] Why was it resolved this way? (design decisions)
- [ ] What alternatives were considered and rejected?
- [ ] What are the edge cases and how does the solution handle them?

### 3. Broader Context
- [ ] Why does this matter?
- [ ] What does this change impact?
- [ ] What could go wrong in the future if someone misunderstands this?
```

Keep this checklist in the conversation — update checkboxes as the human demonstrates understanding.

Show the checklist to the human at the start so they know the map.

### 3. Gauge baseline understanding

Before teaching, ask the human to restate their current understanding of the subject. Use `AskUserQuestion` if helpful. Based on their answer:

- Identify gaps: what they got wrong or left out
- Identify strengths: what they already understand well
- Calibrate depth: adjust your explanations to their level

### 4. Teach incrementally — one checklist item at a time

Work through the checklist in order. For each item:

1. **Explain it** — use the right depth for the human's level. Three explanation modes (the human may ask for any of these):
   - **eli5** — explain like they're 5 (pure analogy, no jargon)
   - **eli14** — explain like they're 14 (light jargon, relatable examples)
   - **elii** — explain like they're an intern (technical but assume no domain background)
2. **Invite questions** — ask if anything is unclear before quizzing
3. **Quiz** — verify understanding with a question (see §5)
4. **Confirm mastery** — only check off the item and proceed once the human has answered correctly

**Never advance to the next checklist item without confirming mastery of the current one.**

### 5. Quiz format

After each explanation, quiz the human using `AskUserQuestion`. Follow these rules:

- **Alternate question types**: mix open-ended and multiple-choice — never use the same type twice in a row
- **For multiple choice**: randomise the position of the correct answer (do not always put it first). Include one plausible-but-wrong distractor that targets a common misconception
- **Do not reveal the correct answer until after the human submits**
- **After submission**: if correct, confirm and explain why. If incorrect, explain the gap and re-teach before moving on — do not just give the answer
- **Drill down into "why"**: even a correct answer should be followed by "and why is that?" at least once per checklist section

Example quiz question format (multiple choice):

> Before we move on — quick check:
>
> [AskUserQuestion with 3–4 options, correct answer in a random position]

Example quiz question format (open-ended):

> In your own words: why does X happen before Y in this flow?
>
> [AskUserQuestion with free-text input, or just ask them to respond in chat]

### 6. Show code when it helps

If a checklist item involves code behaviour, paste the relevant snippet inline and walk through it line by line. If the human needs to explore further, suggest they use the debugger or `console.log` / `print` to observe the behaviour themselves.

### 7. Track and display progress

After each confirmed item, reprint the updated checklist so the human can see their progress. Keep it tight — just the checklist, no commentary.

### 8. End condition

The session does not end until every item on the checklist is checked off and the human has demonstrated understanding through their own words or quiz answers — not just acknowledgement.

When all items are complete, close with:

```
## Session Complete

You've demonstrated understanding of everything on the checklist. Here's a one-paragraph summary of what you now know:

<summary>

If you want to revisit anything, just ask.
```
