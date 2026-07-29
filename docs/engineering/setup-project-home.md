Quickstart:

```bash
npx skills add mattpocock/skills --skill=setup-project-home
```

```bash
npx skills update setup-project-home
```

[Source](https://github.com/mattpocock/skills/tree/main/skills/engineering/setup-project-home)

## What it does

`setup-project-home` records the handful of things about *your* repo that the engineering skills can't work out on their own — whether you triage, what your label strings actually are, and where your domain docs live if they aren't in the usual places.

It is prompt-driven rather than a scaffold — it explores your repo, shows you what it found, and writes only once you've confirmed. It is also deliberately small, for reasons worth understanding before you run it.

## When to reach for it

You invoke this by typing `/setup-project-home` — the agent won't reach for it on its own.

Reach for it **once per repo**, before the first use of [triage](https://aihero.dev/skills-triage), [to-spec](https://aihero.dev/skills-to-spec), or [to-tickets](https://aihero.dev/skills-to-tickets) — if those start applying labels your repo doesn't have, they haven't been set up here yet. You can also re-run it any time: it reads what's already there, shows a diff, and rewrites only its own blocks, leaving the rest of your file alone.

## Prerequisites

A **GitHub repository you can reach** — a GitHub remote, an authenticated `gh`, and Issues enabled. That's the whole prerequisite, and it's a hard one: if any part is missing the skill names which and stops, rather than offering a different tracker or half-configuring the repo.

Nothing else needs to exist first. It is the run-once step that comes *before* the other engineering skills, so it assumes nothing of them.

## Why it's this small

Most of what an agent needs to work in your repo isn't actually variable, and the version of this skill that pretended otherwise cost more than it returned.

It used to ask which issue tracker you used, then write a file describing that tracker's commands, which five other skills read back before they could act. That made a config file a precondition for the toolkit working at all — and when the file was missing, one skill quietly assumed local-markdown files instead of erroring, so *unconfigured* and *configured for markdown* looked identical.

Now **GitHub is the supported tracker** and each skill carries its own GitHub behaviour, so there is nothing to choose and nothing to generate. What's left is genuinely per-repo: your triage label strings, if you triage at all, and the location of your domain docs when they aren't in the usual places. Both are recorded as a short block in the `CLAUDE.md` or `AGENTS.md` you already have — there is no separate config tree, and a repo with defaults everywhere ends the run with nothing written.

That last case is the one worth internalising: **no output is the expected result for most repos**, not a sign the run failed.

## It's working if

- It names the `owner/repo` it resolved, so you can see which repo you configured.
- A repo with no triage habit and docs in the usual places comes out with **nothing written**, and it tells you so rather than treating it as a failure.
- On a re-run you see a diff against what's already there, and your own edits to the surrounding file survive untouched.
- Afterwards, `triage` and `to-tickets` apply labels that exist instead of inventing them.
- Without a reachable GitHub repo, it stops and names the missing piece rather than falling back to anything.

## Where it fits

`setup-project-home` is a **run-once setup**, though a harmless one to repeat. Its neighbours are the skills that read what it writes: [triage](https://aihero.dev/skills-triage), which applies the label vocabulary recorded here, and [to-spec](https://aihero.dev/skills-to-spec) / [to-tickets](https://aihero.dev/skills-to-tickets), which apply `ready-for-agent` as they publish — but only on a repo that triages, and publish unlabelled otherwise. Everything else the skills bring with them. When you're unsure which skill or flow fits, [ask-matt](https://aihero.dev/skills-ask-matt) routes you.
