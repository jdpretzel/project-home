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

It is deliberately small, because most of what a repo needs is not variable. **GitHub is the supported tracker**, so there is no tracker to choose and no command recipes get copied into your repo — each skill carries its own. It is prompt-driven — explore, present what it found, confirm, then write — and on a repo with defaults everywhere it correctly writes nothing at all.

## When to reach for it

You invoke this by typing `/setup-project-home` — the agent won't reach for it on its own.

Reach for it **once per repo**, before the first use of [triage](https://aihero.dev/skills-triage), [to-spec](https://aihero.dev/skills-to-spec), or [to-tickets](https://aihero.dev/skills-to-tickets) — if those start applying labels your repo doesn't have, they haven't been set up here yet. You can also re-run it any time: it reads what's already there, shows a diff, and rewrites only its own blocks, leaving the rest of your file alone.

## Preflight, then two questions

Before anything else it checks you have a **GitHub remote, an authenticated `gh`, and Issues enabled**. If one is missing it stops and says which — it will not offer a different tracker, and it will not half-configure the repo.

Then two questions, each led by a recommended answer you can accept in a word:

- **Does this repo use `/triage`?** Default **no**, and on "no" it writes nothing — a repo that doesn't triage doesn't need a label vocabulary. On "yes" it reconciles the five canonical roles (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`) against the labels you already have, mapping to your strings rather than creating duplicates, and offering to create any that are genuinely missing. It asks here, and only here, whether external pull requests count as requests to triage.
- **Where do your domain docs live?** Only asked as a confirmation. Skills already look for `CONTEXT.md` at the root and ADRs under `docs/adr/`; if that's where yours are, nothing is recorded. Only a genuinely different path — or a monorepo's `CONTEXT-MAP.md` — earns a line.

Whatever it records goes into an `## Agent skills` block in your `CLAUDE.md` or `AGENTS.md` (one file — if they're symlinked it edits the target once). There is no separate config tree.

## It's working if

- It names the `owner/repo` it resolved, so you can see which repo you configured.
- A repo with no triage habit and docs in the usual places comes out with **nothing written**, and it tells you so rather than treating it as a failure.
- On a re-run you see a diff against what's already there, and your own edits to the surrounding file survive untouched.
- Afterwards, `triage` and `to-tickets` apply labels that exist instead of inventing them.
- Without a reachable GitHub repo, it stops and names the missing piece rather than falling back to anything.

## Where it fits

`setup-project-home` is a **run-once setup**, though a harmless one to repeat. Its neighbours are the skills that read what it writes: [triage](https://aihero.dev/skills-triage), which applies the label vocabulary recorded here, and [to-spec](https://aihero.dev/skills-to-spec) / [to-tickets](https://aihero.dev/skills-to-tickets), which apply `ready-for-agent` as they publish. Everything else the skills bring with them. When you're unsure which skill or flow fits, [ask-matt](https://aihero.dev/skills-ask-matt) routes you.
