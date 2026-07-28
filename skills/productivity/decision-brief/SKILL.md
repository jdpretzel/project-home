---
name: decision-brief
description: Present multiple decisions, tradeoffs, or open asks to the user as one decision-brief HTML page. Use whenever a turn would put two or more choices to the user at once — batched questions, option sets, tradeoff comparisons, governance sign-offs — or when the user asks for a decision brief.
---

When you are about to put several decisions to the user at once, don't write a wall of numbered questions — render a **decision brief**: one self-contained HTML page where every open ask is legible at a glance.

Read `${CLAUDE_SKILL_DIR}/BRIEF-FORMAT.html` at the point of need. It is the format contract — a finished specimen, hardened over seven rounds of independent visual review. Reproduce its structure and quality with your content; do not link to it or copy it partially.

What every ask on the page carries, per the specimen:

- **What is being decided** — the question, stated so it stands alone.
- **Why it matters** — the stakes, not the history.
- **The recommended lean** — you always have one; the brief is where you show it.
- **What happens if the reader says nothing** — the default that silence selects.

The page is self-contained: no external requests, light and dark modes both authored. The brief presents decisions — it never makes them. Collect the user's answers in conversation (or via the harness's question tool) after they've read it.
