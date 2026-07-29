---
name: setup-project-home
description: Configure this repo for the engineering skills — verify GitHub access, record where the domain docs live if they're somewhere unusual, and set up triage labels if the repo uses them. Run once before first use of the other engineering skills.
disable-model-invocation: true
---

# Setup Project Home

Record the few things about *this* repo that the engineering skills can't work out for themselves:

- **GitHub access** — that the skills can actually reach this repo's issues
- **Domain doc paths** — only where `CONTEXT.md` or the ADRs aren't where skills already look
- **Triage labels** — the real label strings where this repo uses `/triage`, and the recorded fact that it doesn't where it doesn't

Everything else the skills carry themselves. **GitHub is the supported tracker**, so there is no tracker to choose, and no generic rules or command recipes get copied into your repo. On a repo with defaults everywhere, the one thing this skill still records is the answer to the triage question — and it records it whether that answer was yes or no, because absence has to keep meaning *setup never ran*. A recorded "no" is what stops every consumer from reading an unconfigured repo as one that doesn't triage.

This is a prompt-driven skill, not a deterministic script. Explore, present what you found, confirm with the user, then write.

**Re-running is safe.** It reads what's already there, shows a diff, and rewrites only the blocks it owns — leaving the rest of the file untouched.

## Process

### 1. Preflight — GitHub, or stop

Confirm all three. If any one is missing, **stop and say which**. Do not offer another tracker, do not offer to keep issues in local files, and do not continue to the later sections — the engineering skills cannot function without this, and a repo that silently half-configures is worse than one that plainly refused.

- **A GitHub remote** — `git remote -v`. No remote, or a non-GitHub host, is a stop.
- **Authentication** — `gh auth status`.
- **Issues enabled** — `gh repo view --json nameWithOwner,hasIssuesEnabled`.

Report the resolved `owner/repo` so the user can see exactly which repo they configured — and take that name from the **remote**, not from `gh`. `gh repo view` answers from its own configuration and will hand back a plausible `owner/repo` even in a directory with no remote at all, or one whose remote points at GitLab. Trusting it there configures the skills against a repo the user has never seen. On the stop path there is no resolved repo to report, and saying so is the point.

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

On **no** — create no labels, but still record the answer, as one line in a fixed shape:

> This repo does not triage: publish issues without triage labels.

Recording a "no" looks redundant and isn't: a repo that was asked and answered no has to stay distinguishable from a repo nobody ever asked. Leave it unwritten and every consumer reads *unconfigured* as *triage-off*, publishing unlabelled into a repo that may well triage — the silent fallback this whole design exists to kill, arriving by a new route. The shape is fixed for the same reason the mapping line below is: a re-run with an unchanged answer regenerates identical text rather than a fresh paraphrase. What "no" does still buy is no label vocabulary — nothing manufactured, nothing to go stale.

On **yes** — the five canonical roles are `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. Reconcile them against what `gh label list` returned:

- Already present under those names → record the mapping as identity.
- The repo uses its own strings for the same roles (`bug:triage` for `needs-triage`) → record that mapping, so `/triage` applies the labels that exist rather than creating duplicates.
- A role with no label at all → offer `gh label create`. Ask first; never create labels silently. If a create **fails** — a permissions error is the usual cause — say which labels didn't get created and record the mapping anyway. A recorded role whose label is missing is a `/triage` run that reports one clear error; an abandoned setup is every skill guessing. Don't treat the failure as a reason to re-ask the triage question.

Record the outcome in exactly this shape, so that re-running with unchanged answers regenerates identical text rather than a fresh paraphrase:

> Triage roles map to labels: `needs-triage` → `<label>`, `needs-info` → `<label>`, `ready-for-agent` → `<label>`, `ready-for-human` → `<label>`, `wontfix` → `<label>`. External pull requests: in scope / not in scope.

Write every role on one line, using the canonical name on both sides where the repo hasn't renamed it. It is repetitive on purpose: a fixed shape is what makes the re-run diff show real changes instead of two models' prose styles.

Ask one follow-up here and only here: **do external pull requests count as requests to triage?** Default **no**. On yes, `/triage` pulls external PRs into its queue alongside issues.

**Section B — Domain doc paths.**

The skills already look for `CONTEXT.md` at the repo root and ADRs under `docs/adr/`. Where that's what this repo does, **write nothing** — a default that gets restated is just another thing to keep in sync.

Record a path only where this repo actually differs: ADRs somewhere else, a `CONTEXT-MAP.md` pointing at per-context files, or context docs nested under `src/<context>/`.

Offer the multi-context layout only when exploration found monorepo signals.

### 4. Confirm

Show the exact block about to be written and the file it lands in — files, plural, where step 5 resolves to two independent root instruction files. Where a block already exists, show it as a **diff** against what's there rather than as a fresh insertion, so a re-run makes its changes obvious. Let the user edit before anything is written.

Section B can come back with nothing to record; Section A never does, because "no" is itself the answer it records. So there is always a block to confirm, even when it's a heading and one line — say as much rather than dressing a minimal block up as a bigger result.

### 5. Write

**Pick the file:**

- **Where one is a symlink to the other, edit the target once.** They are the same file; writing "both" writes it twice and can double the block.
- **Where `CLAUDE.md` and `AGENTS.md` both exist as independent files, write the block to both, identically.** An agent whose harness reads only `AGENTS.md` never sees `CLAUDE.md`, so a single-file write is config that half the agents working this repo cannot find — they re-run setup, or act on the defaults the user just overruled.
- If only one exists, edit it. If neither exists, ask which to create — don't pick for them.
- Never create `AGENTS.md` when `CLAUDE.md` already exists, or vice versa. A second root instruction file is a divergence waiting to happen, and this skill shouldn't be what starts one.

The block — `### Triage labels` always, `### Domain docs` only where it earned a place:

```markdown
## Agent skills

### Triage labels

[the mapping in one line and whether external PRs are in scope, or the does-not-triage line]

### Domain docs

[only the paths that differ from the defaults]
```

Three rules make re-runs safe:

- An existing `## Agent skills` section is **updated in place**, sub-block by sub-block. Never append a second one.
- A sub-block whose section answered "nothing nonstandard" is **omitted** — and **removed** if an earlier run wrote one. That is **Domain docs** only: under `### Triage labels`, "no" is a recorded answer rather than an absence, so that sub-block is written either way and never removed.
- Everything outside the sub-blocks this skill owns is left exactly as found. User edits to surrounding sections survive a re-run untouched. Inside a sub-block the recorded **answers** are authoritative and get rewritten from the fixed shape above — so if a hand-edited line disagrees with them, show that as the diff and let the user decide, rather than silently preserving or silently overwriting it.

All three apply **per file**: with two independent root files, each is brought into line with the recorded answers on its own. Where their owned blocks have drifted apart, the recorded answers are still what wins — show the drift as a diff and let the user decide, exactly as with a hand-edited line.

`### Triage labels` is always present, so an empty `## Agent skills` heading is never a correct result — remove one a previous run left behind.

### 6. Done

Say what was written and to which file or files — there is always at least the triage line. Name which engineering skills read it. Mention that these are ordinary lines in the root instructions, editable by hand — re-run this skill only to start over or to change one of the answers. Where you wrote two files, say that both now carry the same block and that hand-editing one alone will make them disagree.
