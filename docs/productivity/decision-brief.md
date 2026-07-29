Quickstart:

```bash
claude plugin marketplace add jdpretzel/project-home
claude plugin install project-home
```

[Source](https://github.com/jdpretzel/project-home/tree/main/skills/productivity/decision-brief)

## What it does

Renders a batch of open decisions as one self-contained HTML page — the **decision brief** — where every ask carries what is being decided, why it matters, the recommended lean, and the default that silence selects. The brief presents decisions but never makes them: it is the surface you read before answering, not a substitute for answering.

The skill owns the format contract, `BRIEF-FORMAT.html` — a finished specimen hardened over seven rounds of independent visual review. Any skill (or bare session) that needs to put several choices to you at once reaches the format by invoking `/decision-brief`, never by linking to the file: skills cannot path into each other's folders, so the invocation *is* the interface.

## When to reach for it

- **Invocation mode.** Type `/decision-brief`, or the agent reaches for it automatically when a turn would put two or more choices to you at once.
- **Trigger boundary.** Reach for this when the decisions already exist and need presenting — batched questions, option sets, tradeoff comparisons, governance sign-offs. To *extract* decisions through interview instead, use [grilling](https://github.com/jdpretzel/project-home/blob/main/skills/productivity/grilling/SKILL.md) — a grilling round with several frontier questions is exactly what this skill then renders.

## The page

One page, every ask legible at a glance: masthead, the ask strip above everything, then per ask the stakes, the lean, and the consequence of saying nothing. Self-contained HTML — no external requests — with light and dark modes both authored.

## Where it fits

A presentation primitive that runs *underneath* the interviewing and planning skills: [wayfinder](https://github.com/jdpretzel/project-home/blob/main/skills/engineering/wayfinder/SKILL.md) resolutions and [grilling](https://github.com/jdpretzel/project-home/blob/main/skills/productivity/grilling/SKILL.md) frontier rounds route their batched asks through it. For the map over the whole skill set, see [ask-matt](https://github.com/jdpretzel/project-home/blob/main/skills/engineering/ask-matt/SKILL.md).
