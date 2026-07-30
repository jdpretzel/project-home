Skills are organized into bucket folders under `skills/`:

- `engineering/` — daily code work
- `productivity/` — daily non-code workflow tools
- `misc/` — kept around but rarely used, not promoted
- `personal/` — tied to my own setup, not promoted
- `in-progress/` — drafts not yet ready to ship
- `deprecated/` — no longer used

Every skill in `engineering/` or `productivity/` (the **promoted** buckets) must have a reference in the top-level `README.md` and an entry in `.claude-plugin/plugin.json`'s `skills` array (the Claude Code plugin ships exactly the promoted set). Skills in `misc/`, `personal/`, `in-progress/`, and `deprecated/` must not appear in either.

The repo is also its own single-plugin Claude Code marketplace: `.claude-plugin/marketplace.json` lists the one `project-home` plugin. The plugin is deliberately version-less: `plugin.json` carries no `version` field, so the git-hosted marketplace treats every commit as a new version and installed users update to whatever `main` holds — cutting a release *is* merging to `main`, nothing else. Do not add a `version` field (to `plugin.json` or the marketplace entry): setting one pins installed users to that string until someone remembers to bump it. Run `claude plugin validate .` after touching either manifest — without `--strict`, deliberately: the validator's only warning here is "no version specified", which is this repo's intended state, and `--strict` would turn that permanent warning into a permanent failure. Why a Claude plugin but not (yet) a Codex one lives in [.agents/adr/0002-ship-as-a-claude-code-plugin.md](./.agents/adr/0002-ship-as-a-claude-code-plugin.md).

Each skill entry in the top-level `README.md` must link the skill name to its `SKILL.md`.

Each bucket folder has a `README.md` that lists every skill in the bucket with a one-line description, with the skill name linked to its `SKILL.md`. The promoted buckets' `README.md`s and the top-level `README.md` group entries into **User-invoked** and **Model-invoked**; non-promoted bucket `README.md`s (`misc/`, `personal/`) use a flat list.

Skills in `engineering/` and `productivity/` also have a human-facing docs page at `docs/<bucket>/<skill-name>.md` (the docs tree mirrors those two bucket folders under `skills/`). The published URL is `https://aihero.dev/skills-<skill-name>` regardless of bucket — the docs path is repo organisation only. When you add, rename, or change the behaviour of a skill in `engineering/` or `productivity/`, create or re-sync its docs page following [.agents/writing-docs.md](./.agents/writing-docs.md). Skills in the non-promoted buckets (`misc/`, `personal/`, `in-progress/`, `deprecated/`) get **no** docs page.

Every `SKILL.md` is either user-invoked (`disable-model-invocation: true` plus `policy.allow_implicit_invocation: false` in `agents/openai.yaml`, reachable only by the human) or model-invoked (model- or user-reachable). See [.agents/invocation.md](./.agents/invocation.md).

[`ask-matt`](./skills/engineering/ask-matt/SKILL.md) is the router that maps every user-reachable skill and how they relate. The same trigger that re-syncs a docs page applies to it: whenever you add, rename, remove, or change how a user-reachable skill fits the flows, re-read `ask-matt`'s `SKILL.md` and update it so the map stays accurate — a new skill it never mentions, or a stale one it still routes to, is a router that lies.

To (re)link every skill into the local harness skill directories (`~/.claude/skills`, `~/.agents/skills`), run `scripts/link-skills.sh`. Each entry is a symlink into this repo, so a `git pull` keeps installed skills current; re-run the script after adding, removing, or renaming a skill.

Run `scripts/check-consistency.sh` before opening a PR. Its scope is deliberately narrow — the tracker invariants from [.agents/adr/0003-github-is-the-supported-tracker.md](./.agents/adr/0003-github-is-the-supported-tracker.md): references to the retired tracker abstraction, and the behaviours that decision requires (the GitHub hard stop, both triage branches, the in-GitHub degradation). It is **prose lint, not behavioural proof** — it greps text, so it can tell you a skill still *says* the right thing, never that a skill still *does* it. Broader enforcement of the README / `plugin.json` / router rules above is deliberately not here; that mechanism is [The router and system legibility](https://github.com/jdpretzel/project-home/issues/13)'s decision to make. Not a substitute for `claude plugin validate .` — run both.

## Agent skills

### Domain docs

ADRs live in `.agents/adr/`, not the default `docs/adr/`. The glossary is `CONTEXT.md` at the repo root, single-context.
