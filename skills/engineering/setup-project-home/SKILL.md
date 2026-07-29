---
name: setup-project-home
description: Configure this repo for the engineering skills — verify GitHub access, record where the domain docs live if they're somewhere unusual, and set up triage labels if the repo uses them. Run once before first use of the other engineering skills.
disable-model-invocation: true
---

# Setup Project Home

Record the few things about *this* repo that the engineering skills can't work out for themselves:

- **GitHub access** — that the skills can actually reach this repo's issues
- **Domain doc paths** — only where `CONTEXT.md` or the ADRs aren't where skills already look
- **Triage labels** — only where this repo actually uses `/triage`

Everything else the skills carry themselves. **GitHub is the supported tracker**, so there is no tracker to choose, and no generic rules or command recipes get copied into your repo. On a repo with defaults everywhere, this skill correctly writes nothing at all.

This is a prompt-driven skill, not a deterministic script. Explore, present what you found, confirm with the user, then write.

**Re-running is safe.** It reads what's already there, shows a diff, and rewrites only the blocks it owns — leaving the rest of the file untouched.

## Process

### 1. Preflight — GitHub, or stop

Confirm all three. If any one is missing, **stop and say which**. Do not offer another tracker, do not offer to keep issues in local files, and do not continue to the later sections — the engineering skills cannot function without this, and a repo that silently half-configures is worse than one that plainly refused.

- **A GitHub remote** — `git remote -v`. No remote, or a non-GitHub host, is a stop.
- **Authentication** — `gh auth status`.
- **Issues enabled** — `gh repo view --json nameWithOwner,hasIssuesEnabled`.

Report the resolved `owner/repo` so the user can see exactly which repo they configured.

### 2. Explore

Read what exists; don't assume:

- `CLAUDE.md` and `AGENTS.md` at the root — which exist, is either a **symlink** to the other, and is there already an `## Agent skills` section?
- `CONTEXT.md` and `CONTEXT-MAP.md`, at the root or elsewhere
- ADR directories — `docs/adr/`, `src/*/docs/adr/`, or somewhere else entirely
- `gh label list` — what label vocabulary already exists
- Monorepo signals — a `pnpm-workspace.yaml`, a `workspaces` field in `package.json`, or a populated `packages/*` with its own `src/`. Absent means single-context, which is almost every repo.
- A leftover `docs/agents/` directory — output from an older version of this skill. Its `issue-tracker.md` is obsolete: the tracker is no longer configurable, so nothing reads that file. Offer to delete it; don't delete without asking.

### 3. Present findings and ask

Summarise what's present and what's missing, then take the two sections in order — one section, one answer, then the next. Lead each with the recommended answer so it can be accepted in a word, and skip a section outright when exploration already settled it.

**Section A — Does this repo use `/triage`?**

> Do you triage incoming issues on this repo? (recommended: **no**, unless you already have a triage habit)

Ask about *use*, never about whether the skill is installed: `triage` ships in this same plugin, so "installed" is true in every repo and gates nothing.

On **no** — write nothing. No labels, no block. A repo that doesn't triage doesn't need a label vocabulary, and manufacturing one only leaves config to go stale.

On **yes** — the five canonical roles are `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. Reconcile them against what `gh label list` returned:

- Already present under those names → record the mapping as identity.
- The repo uses its own strings for the same roles (`bug:triage` for `needs-triage`) → record that mapping, so `/triage` applies the labels that exist rather than creating duplicates.
- A role with no label at all → offer `gh label create`. Ask first; never create labels silently.

Ask one follow-up here and only here: **do external pull requests count as requests to triage?** Default **no**. On yes, `/triage` pulls external PRs into its queue alongside issues.

**Section B — Domain doc paths.**

The skills already look for `CONTEXT.md` at the repo root and ADRs under `docs/adr/`. Where that's what this repo does, **write nothing** — a default that gets restated is just another thing to keep in sync.

Record a path only where this repo actually differs: ADRs somewhere else, a `CONTEXT-MAP.md` pointing at per-context files, or context docs nested under `src/<context>/`.

Offer the multi-context layout only when exploration found monorepo signals.

### 4. Confirm

Show the exact block about to be written and the file it lands in. Where a block already exists, show it as a **diff** against what's there rather than as a fresh insertion, so a re-run makes its changes obvious. Let the user edit before anything is written.

Where both sections came back "nothing to record", say so and write nothing. That is a successful run, not a failure.

### 5. Write

**Pick the file:**

- If `CLAUDE.md` exists, edit it. Else if `AGENTS.md` exists, edit it.
- If neither exists, ask which to create — don't pick for them.
- Never create `AGENTS.md` when `CLAUDE.md` already exists, or vice versa.
- **Where one is a symlink to the other, edit the target once.** They are the same file; writing "both" writes it twice and can double the block.

The block, carrying only the sub-blocks that earned a place:

```markdown
## Agent skills

### Triage labels

[the mapping in one line, and whether external PRs are in scope]

### Domain docs

[only the paths that differ from the defaults]
```

Three rules make re-runs safe:

- An existing `## Agent skills` section is **updated in place**, sub-block by sub-block. Never append a second one.
- A sub-block whose section answered "no" or "nothing nonstandard" is **omitted** — and **removed** if an earlier run wrote one.
- Everything outside the sub-blocks this skill owns is left exactly as found. User edits to surrounding sections, and to the prose inside a block, survive a re-run.

If both sub-blocks are omitted, don't write an empty `## Agent skills` heading — and remove one a previous run left behind.

### 6. Done

Say what was written, or that nothing needed writing. Name which engineering skills read it. Mention that these are ordinary lines in the root instructions, editable by hand — re-run this skill only to start over or to change one of the answers.
