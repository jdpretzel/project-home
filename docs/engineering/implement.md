Quickstart:

```bash
npx skills add mattpocock/skills --skill=implement
```

```bash
npx skills update implement
```

[Source](https://github.com/mattpocock/skills/tree/main/skills/engineering/implement)

## What it does

`implement` builds the work described in a spec or a set of tickets — driving it through test-driven development, typechecking, and the full test suite, then committing, reviewing that commit, and opening a draft pull request. It runs unattended from end to end; the only thing it stops for is your decision to merge.

It does **not** decide what to build. The spec is already settled and the seams are already agreed; `implement` executes that plan rather than reopening it. It is the hands, not the head — the thinking happened upstream.

## When to reach for it

You invoke this by typing `/implement` — the agent won't reach for it on its own.

Reach for it once the work is written down as a spec or split into tickets and you're ready to turn that into code. If the spec doesn't exist yet, write it first — for that, use [to-spec](https://aihero.dev/skills-to-spec), or [to-tickets](https://aihero.dev/skills-to-tickets) to break a spec into tickets. If you just want to build something test-first without a full spec, drop to [tdd](https://aihero.dev/skills-tdd) directly.

## Prerequisites

A GitHub repo you can reach gets the full loop — the commit's `Closes #<n>` reference is how the review finds its spec, and the run ends on an open draft PR. A repo with no remote is still supported: the run does everything else and stops at the reviewed branch instead of a PR. Without a ticket the review's Spec axis falls back to a spec file, or skips and says so.

A ticket whose blockers have already merged. Dependent work branches off the default branch — or off the integration branch when the ticket names one — so it can only see a blocker's changes once that blocker's pull request has landed. Independent tickets on the frontier still run in parallel.

Where the repo provides a lifecycle entry — a script like `scripts/agent-lifecycle.sh` that owns starting work — `implement` goes through it rather than driving git itself: the entry fetches, resolves the base to an exact commit, and hands back an isolated worktree to work and plan in. Where there is no such entry it does the same thing by hand, fetching first and branching off the base's remote-tracking ref (`origin/main` and the like), since fetch updates those and not your local copies, and a stale base hides merged blockers. Either way the build happens in a worktree, never in your primary checkout.

## Pre-agreed seams

The idea `implement` runs on is the **seam** — the stable interface a feature is tested at, chosen before any code is written. It doesn't invent seams mid-build; it uses the ones already picked (during [to-spec](https://aihero.dev/skills-to-spec)) and writes tests against them via [tdd](https://aihero.dev/skills-tdd). Working at pre-agreed seams is what keeps the implementation honest: the tests target something durable, so the code underneath can move without the tests moving.

Around that core it keeps the loop tight — typecheck often, run single test files as it goes, run the whole suite once at the end.

## The commit is the checkpoint

[code-review](https://aihero.dev/skills-code-review) reads committed history, not your working tree. So `implement` commits *before* it reviews. That commit is not a claim the work is finished — it is what makes the work visible to a reviewer at all, and everything after it is correction in the open: findings come back as narrow fix-up commits, and substantive fixes earn another pass.

The pull request is an additional review surface, not a substitute for that in-run review. Waiting until the PR to review would move the substance out of the run and into your inbox, which is the opposite of the point.

Publishing that checkpoint is deliberately narrow. Where the repo has a pre-publication check (`scripts/agent-lifecycle.sh publish-check`), it runs first — it re-fetches, shows whether the base has moved underneath the work, and stops on changes to authority-carrying paths, which alter what a push *does* and so need you before their first push. Then one topic branch is pushed, never force, and a **draft** PR opens immediately, with the remote head and the PR's base and head verified afterwards rather than assumed. Draft is the honest state: the work is reviewed and visible, and it is still yours to promote and merge.

## It's working if

- Nothing pauses to ask you for permission to push or to open the PR — unless the change touches an authority-carrying path, which stops before its first push.
- Whatever review finds lands as separate fix-up commits, rather than being amended back into the implementation commit.
- The run ends on an open draft PR, its remote head and base/head verified — or, in a repo with no remote, on a reviewed branch reported ready to merge — with the merge left to you.

## Where it fits

`implement` is the build step near the end of the main chain, and it now carries the review inside it rather than handing off to it:

```txt
grill-with-docs → to-spec → to-tickets → implement (tdd → commit → code-review → draft PR)
```

Reach for it after the work has been specced and sequenced, not before. Its key neighbours are [to-tickets](https://aihero.dev/skills-to-tickets), which produces the tickets — each declaring its blocking edges — that it works through, and [tdd](https://aihero.dev/skills-tdd), which it drives internally to write the tests at each seam before its own [code-review](https://aihero.dev/skills-code-review) pass. When you're unsure which skill or flow fits, [ask-matt](https://aihero.dev/skills-ask-matt) routes you.
