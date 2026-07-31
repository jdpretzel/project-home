# project-home

The plugin half of **Project Home**: one plugin install, one command, and a new
project begins. Pairs with
[project-home-template](https://github.com/jdpretzel/project-home-template), the
repo template that `/new-project` seeds new projects from.

Carries the full skill set forked from upstream (see below). Project Home's own
additions — model routing defaults, the lexicon system, and the `/new-project`
wrapper — are still to land. Every skill carries Codex-side metadata
(`agents/openai.yaml`), but `~/.claude/plugins/` is not a path Codex reads:
installing this plugin delivers nothing to Codex, and there is no separate Codex
plugin.

## Install

```bash
claude plugin marketplace add jdpretzel/project-home
claude plugin install project-home
```

## Status

Charting. Decisions are tracked as a wayfinder map in this repo's issues — look
for the `wayfinder:map` label.

## Skills

The promoted set, grouped by who can reach them. User-invoked skills fire only
when you type them; model-invoked skills the agent can also reach on its own.

### User-invoked

- **[ask-matt](skills/engineering/ask-matt/SKILL.md)** — Ask which skill or flow fits your situation; a guide to the main skill flows in this repo.
- **[grill-with-docs](skills/engineering/grill-with-docs/SKILL.md)** — Grilling session that also builds your project's domain model, updating `CONTEXT.md` and ADRs inline.
- **[triage](skills/engineering/triage/SKILL.md)** — Move issues through a state machine of triage roles.
- **[improve-codebase-architecture](skills/engineering/improve-codebase-architecture/SKILL.md)** — Scan a codebase for deepening opportunities, presented as a visual HTML report.
- **[setup-project-home](skills/engineering/setup-project-home/SKILL.md)** — Configure this repo for the engineering skills: verify GitHub access, triage labels if you use them, unusual doc paths. Run once per repo.
- **[to-spec](skills/engineering/to-spec/SKILL.md)** — Turn the current conversation into a spec and publish it as a GitHub issue.
- **[to-tickets](skills/engineering/to-tickets/SKILL.md)** — Break a plan or spec into tracer-bullet tickets, each declaring its blocking edges.
- **[implement](skills/engineering/implement/SKILL.md)** — Build the work a spec or ticket describes, driving `/tdd` internally, then committing, running `/code-review` against that commit, and opening a PR.
- **[wayfinder](skills/engineering/wayfinder/SKILL.md)** — Plan a huge chunk of work as a shared map of decision tickets, resolved one at a time until the way is clear.
- **[grill-me](skills/productivity/grill-me/SKILL.md)** — Get relentlessly interviewed about a plan or design until every branch of the decision tree is resolved.
- **[handoff](skills/productivity/handoff/SKILL.md)** — Compact the current conversation into a handoff document so another agent can continue the work.
- **[teach](skills/productivity/teach/SKILL.md)** — Learn a skill or concept over multiple sessions, using the current directory as a stateful workspace.
- **[writing-great-skills](skills/productivity/writing-great-skills/SKILL.md)** — Reference for writing and editing skills well.

### Model-invoked

- **[diagnosing-bugs](skills/engineering/diagnosing-bugs/SKILL.md)** — Disciplined diagnosis loop for hard bugs and performance regressions.
- **[research](skills/engineering/research/SKILL.md)** — Investigate a question against primary sources and capture the findings as a cited Markdown file, run in the background.
- **[tdd](skills/engineering/tdd/SKILL.md)** — Test-driven development with a red-green-refactor loop.
- **[domain-modeling](skills/engineering/domain-modeling/SKILL.md)** — Build and sharpen a project's domain model; challenge terms, record ADRs.
- **[codebase-design](skills/engineering/codebase-design/SKILL.md)** — Shared vocabulary for designing deep modules: small interfaces, clean seams.
- **[code-review](skills/engineering/code-review/SKILL.md)** — Two-axis review (Standards + Spec) of the diff since a fixed point.
- **[resolving-merge-conflicts](skills/engineering/resolving-merge-conflicts/SKILL.md)** — Work through an in-progress merge or rebase conflict hunk by hunk, by intent.
- **[prototype](skills/engineering/prototype/SKILL.md)** — Build a throwaway prototype to answer a design question.
- **[decision-brief](skills/productivity/decision-brief/SKILL.md)** — Present multiple decisions or tradeoffs to the user as one decision-brief HTML page.
- **[grilling](skills/productivity/grilling/SKILL.md)** — Interview the user relentlessly about a plan, decision, or idea until every branch is resolved.

## Attribution

Forked from [mattpocock/skills](https://github.com/mattpocock/skills) at commit
[`9c32629965586e75a9d2206922dccec91e19f2f2`](https://github.com/mattpocock/skills/commit/9c32629965586e75a9d2206922dccec91e19f2f2)
on upstream's `release/v1.2` branch. MIT, © 2026 Matt Pocock — the original
[LICENSE](LICENSE) notice is kept intact, and the upstream README is preserved
as [UPSTREAM-README.md](UPSTREAM-README.md). That commit SHA is the anchor for
any future diff against upstream.
