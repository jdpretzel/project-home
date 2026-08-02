Quickstart:

```bash
claude plugin marketplace add jdpretzel/project-home
claude plugin install project-home
```

[Source](https://github.com/jdpretzel/project-home/tree/main/skills/engineering/resolving-merge-conflicts)

## What it does

`resolving-merge-conflicts` works through an in-progress git merge or rebase conflict, hunk by hunk, and carries the operation to a resolved, checked, committed end — once it has established that this is an operation worth finishing.

It resolves by **intent**, not by text. Before touching a hunk it traces each side back to its **primary source** — the commit message, the PR, the original issue — to understand why the change was made, then preserves both intents where they're compatible, and never invents new behaviour to paper over a clash. What it won't do is treat finishing as the only acceptable outcome: an operation that should never have started is resolved by aborting it, not by resolving its hunks well.

## When to reach for it

Type `/resolving-merge-conflicts`, or the agent reaches for it automatically when a task fits.

Reach for this when you're mid-merge or mid-rebase and git has stopped on conflicts it can't resolve itself. It's for the conflict in front of you — not for planning the merge or for debugging behaviour that broke afterwards. If the merge is done but something's now failing for reasons you can't see, use [diagnosing-bugs](https://aihero.dev/skills-diagnosing-bugs) instead.

## First, whether the operation should be finished

A conflict is evidence that git stopped, not evidence that finishing is right. So the first move isn't the first hunk — it's the situation around it: which checkout this is (a task worktree, not someone's primary checkout), which operation is in flight, whether its base and head are the intended ones, whether the tree was clean before it started, and whether finishing is even yours to do — a rebase of published history, for one, isn't.

When any of those comes back wrong — the operation is accidental, unauthorized, on the wrong base, or on top of unrelated dirty work — **`--abort` is the correct resolution**: preserve the state, abort, and say what was wrong and what to run instead. Resolving hunks in that situation is worse than useless. It produces a well-reasoned commit nobody asked for, on a base nobody chose, and buries the mistake under work that now looks deliberate.

## Resolving by intent

The trap in a conflict is treating it as a text problem — picking "ours" or "theirs" to make the markers go away. This skill treats it as an **intent** problem. Each side of a hunk exists because someone wanted something; the resolution has to honour both wants where it can, and where they're genuinely incompatible, pick the one that matches the merge's stated goal and note the trade-off out loud.

That's why the primary sources matter. You can't preserve an intent you haven't read, so the work starts in the history — commits, PRs, tickets — not in the diff.

## It's working if

- Each resolved hunk keeps both sides' behaviour, or names the trade-off where it couldn't.
- No new behaviour appears that wasn't on either branch.
- The project's own checks — typecheck, tests, format — are found and run green before the commit.
- The checkout, operation, base and authority are established before the first hunk is touched.
- A merge or rebase that shouldn't have started is aborted with the reason named, not resolved into a commit.

## Where it fits

A reach-for-it-anytime standalone: you invoke it at the moment a merge or rebase stalls, and it hands you back a clean tree — the operation either finished and committed, or aborted with the reason named. Its natural neighbour is [diagnosing-bugs](https://aihero.dev/skills-diagnosing-bugs), because a merge that resolves cleanly but misbehaves afterwards is a diagnosis problem, not a conflict one. When you're unsure which skill fits, [ask-matt](https://aihero.dev/skills-ask-matt) routes you.
