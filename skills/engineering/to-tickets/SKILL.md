---
name: to-tickets
description: Break a plan, spec, or the current conversation into a set of tracer-bullet tickets, each declaring its blocking edges, published as GitHub issues — edges as native issue dependencies, or as Blocked by lines where the repo lacks them.
disable-model-invocation: true
---

# To Tickets

Break a plan, spec, or conversation into a set of **tickets** — tracer-bullet vertical slices, each declaring the tickets that **block** it.

Tickets are published as GitHub issues on this repo. If this repo triages, its label vocabulary should have been provided to you — run `/setup-project-home` if not. A repo that doesn't triage is a supported case, not a misconfiguration.

## Process

### 1. Gather context

Work from whatever is already in the conversation context. If the user passes a reference (a spec path, an issue number or URL) as an argument, fetch it and read its full body and comments.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code. Ticket titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

Look for opportunities to prefactor the code to make the implementation easier. "Make the change easy, then make the easy change."

### 3. Draft vertical slices

Break the work into **tracer bullet** tickets.

<vertical-slice-rules>

- Each slice cuts a narrow but COMPLETE path through every layer (schema, API, UI, tests) — vertical, NOT a horizontal slice of one layer
- A completed slice is demoable or verifiable on its own
- Each slice is sized to fit in a single fresh context window
- Any prefactoring should be done first

</vertical-slice-rules>

Give each ticket its **blocking edges** — the other tickets that must complete before it can start. A ticket with no blockers can start immediately.

**Wide refactors are the exception to vertical slicing.** A **wide refactor** is one mechanical change — rename a column, retype a shared symbol — whose **blast radius** fans across the whole codebase, so a single edit breaks thousands of call sites at once and no vertical slice can land green. Don't force it into a tracer bullet; sequence it as **expand–contract**. First expand: add the new form beside the old so nothing breaks. Then migrate the call sites over in batches sized by blast radius (per package, per directory), each batch its own ticket blocked by the expand, keeping CI green batch to batch because the old form still exists. Finally contract: delete the old form once no caller remains, in a ticket blocked by every migrate batch. When even the batches can't stay green alone, keep the sequence but let them share an integration branch that all block a final integrate-and-verify ticket — green is promised only there. Name the branch in every ticket that lands on it — the batches, the contract, and the final integrate-and-verify — so /implement branches off it rather than the default branch.

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each ticket, show:

- **Title**: short descriptive name
- **Blocked by**: which other tickets (if any) must complete first
- **What it delivers**: the end-to-end behaviour this ticket makes work

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the blocking edges correct — does each ticket only depend on tickets that genuinely gate it?
- Should any tickets be merged or split further?

Iterate until the user approves the breakdown.

### 5. Publish the tickets as GitHub issues

**Check these three first, before creating anything** — an error returned by the first `gh issue create` is a worse way to discover them, because by then something may already exist:

- **GitHub remote** — `git remote -v`. Read the repo name from the remote, not from `gh`, which answers from its own config even when the remote is absent or points elsewhere.
- **Authentication** — `gh auth status`.
- **Issues enabled** — `gh repo view --json nameWithOwner,hasIssuesEnabled`.

If any fails, **stop and say which**. Don't publish the tickets anywhere else instead — not local files, not Discussions, not a project board, not a checklist pasted into another issue. The tickets exist so `/implement` can pick them off GitHub; somewhere else is not a lesser version of that, it's a different artifact.

Then publish one issue per ticket **in dependency order** (blockers first), so each ticket's blocking edges can reference real issue numbers.

Where this repo has a triage vocabulary, apply its `ready-for-agent` label unless instructed otherwise — the tickets are agent-grabbable by construction. Where it doesn't triage, publish without a label and say so; don't fail the publish over a label that was never meant to exist, and don't create one.

**Wiring the blocking edges.** Prefer GitHub's native issue dependencies, which render the frontier visually in GitHub's own UI:

```bash
gh api --method POST repos/{owner}/{repo}/issues/<blocked>/dependencies/blocked_by \
  -F issue_id=<blocker-db-id>
```

`<blocker-db-id>` is the blocker's numeric **database id**, from `gh api repos/{owner}/{repo}/issues/<n> --jq .id` — **not** the `#number` you see in the UI, and not the `node_id`. Passing the issue number here is the trap: it either fails or silently wires the wrong issue, because low issue numbers are also valid database ids belonging to entirely different repositories.

There is no field that advertises whether dependencies are available, so find out by trying: wire the first edge, and if the API rejects it, fall back for **all** of them rather than leaving the set half-wired in two different representations.

The fallback is a `Blocked by: #<n>, #<n>` line at the top of each blocked ticket's body. **Say that you did**, once, as you publish — otherwise the frontier looks unwired to anyone who checks GitHub's dependency graph and finds it empty.

Note the asymmetry, because it is the difference between a stop and a shrug: no remote, no auth, or no Issues is a **hard stop**, while missing dependencies is a **degradation** — a named substitute for the same information on the same tracker. A degradation always ships a replacement; a hard stop never does.

Work the **frontier**: any ticket whose blockers have all landed. For a purely linear chain that means top to bottom.

Do NOT close or modify any parent issue.

<issue-template>

## Parent

A reference to the parent issue on this repo (if the source was an existing issue, otherwise omit this section).

## What to build

The end-to-end behaviour this ticket makes work, from the user's perspective — not layer-by-layer implementation.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Blocked by

- A reference to each blocking ticket, or "None — can start immediately".

</issue-template>

In either form, avoid specific file paths or code snippets — they go stale fast. Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it and note briefly that it came from a prototype. Trim to the decision-rich parts — not a working demo, just the important bits.

Work the frontier one ticket at a time with `/implement`, clearing context between tickets.
