Quickstart:

```bash
npx skills add mattpocock/skills --skill=code-review
```

```bash
npx skills update code-review
```

[Source](https://github.com/mattpocock/skills/tree/main/skills/engineering/code-review)

## What it does

`code-review` reviews the diff between `HEAD` and a fixed point you supply — a commit, branch, tag, or merge-base — along two separate axes: **Standards** (does the code follow this repo's documented conventions?) and **Spec** (does it implement what the originating issue or spec asked for?). It runs each axis as its own parallel sub-agent and reports them side by side. It never merges or re-ranks the two sets of findings — keeping them separate is the whole point, because a change can pass one axis and fail the other, and a single blended verdict lets one mask the other.

## When to reach for it

Type `/code-review`, or the agent reaches for it automatically when you ask to review a branch, a PR, work-in-progress changes, or anything "since X".

Reach for this when there is a diff to judge against a known-good point and you want the two questions — *is it built right?* and *is it the right thing?* — answered independently. It runs at the end of the build loop; for actually writing the code test-first, use [tdd](https://aihero.dev/skills-tdd), and for building a whole spec into code use [implement](https://aihero.dev/skills-implement), which commits and then runs its own `/code-review` pass against that commit.

## Prerequisites

The **Spec** axis needs somewhere to find the originating spec — an issue reference in the commit messages, a path you pass in, or a spec under `docs/`/`specs/`. An issue reference is fetched from the repo's GitHub issues, so it is only readable where the repo is reachable: a GitHub remote, `gh` authenticated, and Issues enabled. That is checked before the reference is trusted, and if a check fails the skill names which one — "`gh` is not authenticated, so I can't read #45" — and falls through to the next spec source rather than pretending the reference was never there. Having no spec and being unable to read the spec you have are different outcomes, and the report keeps them apart. The **Standards** axis needs nothing set up — it always carries a built-in Fowler smell baseline even in a repo that documents no conventions.

## Two axes, never merged

The defining idea is the **two axes**. **Standards** asks whether the diff conforms to how this repo writes code — its `CODING_STANDARDS.md` or `CONTRIBUTING.md`, plus a fixed baseline of ~12 Fowler code smells (Mysterious Name, Duplicated Code, Feature Envy, Data Clumps, …). Two rules keep the baseline safe: a documented repo standard always overrides it, and every smell is a judgement call, never a hard violation. **Spec** asks the orthogonal question — does the code do what the issue or spec actually asked, without missing requirements or smuggling in scope creep?

They run as parallel sub-agents so neither pollutes the other's context, and the final report presents them under separate `## Standards` and `## Spec` headings with a per-axis summary. There is deliberately no single winner across axes.

The Spec axis has three outcomes, not two, and you will see the difference in the report. **Found** — the spec is readable, so the axis runs. **Absent** — you have said there is no spec, so the axis skips and reports "no spec available". **Blocked** — a spec was identified but couldn't be read (an issue reference behind an unauthenticated `gh` or a repo with Issues disabled, a path you lack access to), so the axis skips and reports **"Spec axis blocked: `<what>` — `<why>`"**. Blocked is never folded into absent, because "no spec available" tells you the change had nothing to conform to, when in fact nobody checked.

## The reviewed range is pinned

A branch name is not a range. `main` today and `main` an hour from now can name different commits, so a review that diffs against a name can quietly end up judging something other than what it reported on. `code-review` resolves both ends to **immutable SHAs once**, up front — the fixed point and `HEAD` — and every later step uses those, so the range can't drift mid-review while two sub-agents are running.

The same honesty applies to what the range can't see. A committed-range diff shows nothing of your dirty or untracked files, so those are listed in the report as **outside the reviewed range**: otherwise "review passed" would quietly claim more than was reviewed. And when the findings are assembled, `HEAD` is checked once more against the SHA the review started from — if commits landed in the meantime, the review covered a stale range, and it says so and asks to be re-run rather than reporting on a snapshot that no longer exists.

## It's working if

- It resolves the fixed point and `HEAD` to SHAs first and diffs those, failing fast on a bad ref or empty diff rather than inside the sub-agents.
- Dirty or untracked files are named in the report as outside the reviewed range, rather than passing unmentioned.
- If `HEAD` moved while the review ran, you're told the range went stale instead of being handed the findings anyway.
- Standards and Spec findings arrive in two distinct blocks, each citing its source — a repo standard or baseline smell for one, a quoted spec line for the other.
- When no spec can be found, the Spec axis reports "no spec available" instead of inventing requirements.
- When a spec *was* identified but couldn't be read, you get "Spec axis blocked: `<what>` — `<why>`" and are told which prerequisite failed — never "no spec available", which would read as if there had been nothing to check against.

## Where it fits

`code-review` is the review step at the tail of the main build chain:

```txt
grill-with-docs → to-spec → to-tickets → implement → code-review
```

Its closest neighbour is [implement](https://aihero.dev/skills-implement), which drives the build, commits, and calls this as its own review pass against that commit; upstream, the spec it checks against is produced by [to-spec](https://aihero.dev/skills-to-spec) and [to-tickets](https://aihero.dev/skills-to-tickets). When you're unsure which skill or flow fits, [ask-matt](https://aihero.dev/skills-ask-matt) routes you.
