# Working in this repo

## Agent repository lifecycle

Agents may inspect this primary checkout but never mutate it — no edits, commits, merges, rebases, branch switches, or stashes here. Every mutating task, whatever skill or request started it, begins with:

    scripts/agent-lifecycle.sh start <branch>

which fetches `origin`, resolves the remote default branch (or `--base <remote-branch>`) to an exact commit, creates an isolated worktree at that commit, and records the base. If the fetch fails, mutating work stops — never fall back silently to a cached or local base. Plan *inside* the worktree, recording the base commit, intended scope, and publication endpoint. Review against immutable SHAs (resolve the base and `HEAD` once), and account for dirty and untracked files, which committed-range diffs don't show.

Before publishing, run `scripts/agent-lifecycle.sh publish-check`: it re-fetches, exposes base advancement, and stops on authority-carrying paths (`.claude/`, `.codex/`, `.github/`, `.claude-plugin/`, the lifecycle scripts) — those need owner approval before their first push. Ordinary reviewed work publishes unattended: push the one topic branch (never force), immediately open a **draft** PR, verify the remote head and the PR's base/head, then pause. Merge, force-push, rewriting published history, default-branch pushes, tags, releases, settings changes, and installs are owner-approved actions. Rebase only unpublished, privately owned history; once a branch is published or shared, merge the current base into it instead. Aborting a wrong merge or rebase is a valid outcome — verify the operation, checkout, base, and authority before finishing one. Remove a worktree only through `scripts/agent-lifecycle.sh close`, which proves no dirty, untracked, or unpushed work would be lost. Rationale and boundaries: [.agents/adr/0004-agent-repository-lifecycle.md](./.agents/adr/0004-agent-repository-lifecycle.md).

## Skill buckets

Skills are organized into bucket folders under `skills/`:

- `engineering/` — daily code work
- `productivity/` — daily non-code workflow tools
- `misc/` — kept around but rarely used, not promoted
- `personal/` — tied to my own setup, not promoted
- `in-progress/` — drafts not yet ready to ship
- `deprecated/` — no longer used

`engineering/` and `productivity/` are the **promoted** buckets — the Claude Code plugin ships exactly that set.

## Promotion surfaces

Promotion into `engineering/` or `productivity/` adds three requirements — a promoted skill must have all three:

- **A top-level `README.md` reference**, with the skill name linked to its `SKILL.md`.
- **An entry in `.claude-plugin/plugin.json`'s `skills` array.**
- **A human-facing docs page** at `docs/<bucket>/<skill-name>.md` — the docs tree mirrors those two bucket folders under `skills/`. The published URL is `https://aihero.dev/skills-<skill-name>` regardless of bucket; the docs path is repo organisation only. When you add, rename, or change the behaviour of a skill in `engineering/` or `productivity/`, create or re-sync its docs page following [.agents/writing-docs.md](./.agents/writing-docs.md).

Skills in `misc/`, `personal/`, `in-progress/`, and `deprecated/` must not appear in the top-level `README.md` or in `.claude-plugin/plugin.json`'s `skills` array, and get **no** docs page.

These three are what promotion *adds*, not the whole job of adding a skill: every skill, promoted or not, also needs a bucket `README.md` entry and invocation metadata, and any user-reachable skill needs the router kept current. All three are below.

## The router

[`ask-matt`](./skills/engineering/ask-matt/SKILL.md) maps the main skill flows in this repo and how they relate. The same trigger that re-syncs a docs page applies to it: whenever you add, rename, remove, or change how a skill fits those flows, re-read `ask-matt`'s `SKILL.md` and update it so the map stays accurate — a skill whose place in the flows it never mentions, or a stale one it still routes to, is a router that lies.

Which skills the router is *obliged* to cover — every promoted skill, every locally installed one, or something else — is [#13](https://github.com/jdpretzel/project-home/issues/13), still open. It does not cover all of them today.

## READMEs

- Each bucket folder has a `README.md` that lists every skill in the bucket with a one-line description, with the skill name linked to its `SKILL.md`.
- The promoted buckets' `README.md`s and the top-level `README.md` group entries into **User-invoked** and **Model-invoked**; non-promoted bucket `README.md`s (`misc/`, `personal/`) use a flat list.

## Invocation

Every `SKILL.md` is either user-invoked (`disable-model-invocation: true` plus `policy.allow_implicit_invocation: false` in `agents/openai.yaml`, reachable only by the human) or model-invoked (model- or user-reachable). See [.agents/invocation.md](./.agents/invocation.md).

## Plugin and marketplace

The repo is also its own single-plugin Claude Code marketplace: `.claude-plugin/marketplace.json` lists the one `project-home` plugin.

- **The plugin is deliberately version-less.** `plugin.json` carries no `version` field, so Claude Code resolves the version from the source's git commit SHA — every commit is a distinct version, and merging to `main` publishes one. Installed users receive it at their next `/plugin update` or background auto-update, not at merge time. Cutting a release *is* merging to `main`, nothing else.
- **Do not add a `version` field** (to `plugin.json` or the marketplace entry): setting one pins installed users to that string until someone remembers to bump it.
- **Validate without `--strict`.** Run `claude plugin validate .` after touching either manifest — without `--strict`, deliberately: the validator's only warning here is "no version specified", which is this repo's intended state, and `--strict` would turn that permanent warning into a permanent failure.

Why a Claude plugin but not (yet) a Codex one lives in [.agents/adr/0002-ship-as-a-claude-code-plugin.md](./.agents/adr/0002-ship-as-a-claude-code-plugin.md).

## Scripts

- **`scripts/agent-lifecycle.sh`** — the deterministic owner of the agent lifecycle's Git mechanics: `start` (fetch, exact remote base, isolated worktree), `preflight`/`status` (read-only state), `publish-check` (pre-publication proofs and the authority-path stop), `close` (proof-before-cleanup removal). The hooks in `.claude/settings.json` and `.codex/hooks.json` are thin adapters around it and `scripts/agent-lifecycle-guard.py`; the guard blocks primary-checkout mutation, force pushes, and forced worktree removal. Tested by `scripts/test-agent-lifecycle.sh` in temporary repositories.
- **`scripts/link-skills.sh`** — links every skill outside `deprecated/` into the local harness skill directories (`~/.claude/skills`, `~/.agents/skills`). Each entry is a symlink into this repo, so a `git pull` keeps installed skills current; re-run it after adding or renaming a skill. Two things it does not do, both live in [#29](https://github.com/jdpretzel/project-home/issues/29): it never prunes, so a link whose target was renamed or deleted survives until removed by hand, and it writes outside the repo — `rm -rf`-ing any conflicting non-symlink entry, including skills installed from elsewhere. Run it attended.
- **`scripts/check-consistency.sh`** — run before opening a PR. Its scope is deliberately narrow: the tracker invariants from [.agents/adr/0003-github-is-the-supported-tracker.md](./.agents/adr/0003-github-is-the-supported-tracker.md) — references to the retired tracker abstraction, and the behaviours that decision requires (the GitHub hard stop, both triage branches, the in-GitHub degradation). It is **prose lint, not behavioural proof** — it greps text, so it can tell you a skill still *says* the right thing, never that a skill still *does* it. Broader enforcement of the README / `plugin.json` / router rules above is deliberately not here; that mechanism is [The router and system legibility](https://github.com/jdpretzel/project-home/issues/13)'s decision to make. Not a substitute for `claude plugin validate .` — run both.

## Agent skills

### Triage labels

This repo does not triage: publish issues without triage labels.

### Domain docs

ADRs live in `.agents/adr/`, not the default `docs/adr/`. The glossary is `CONTEXT.md` at the repo root, single-context.
