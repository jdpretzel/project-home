---
name: resolving-merge-conflicts
description: "Use when you need to resolve an in-progress git merge/rebase conflict."
---

1. **See the current state** of the merge/rebase, and whether it should exist at all. Check git history and the conflicting files — and also: which checkout this is (a task worktree, not someone's primary checkout), which operation is in flight, whether its base and head are the intended ones, whether the tree was clean before it started, and whether you have the authority for what finishing would do (a rebase of published history, for instance, isn't yours to finish). If the operation is accidental, unauthorized, on the wrong base, or on top of unrelated dirty work, **`--abort` is the correct resolution** — preserve the state, abort, and say what was wrong and what to run instead.

2. **Find the primary sources** for each conflict. Understand deeply why each change was made, and what the original intent was. Read the commit messages, check the PRs, check original issues/tickets.

3. **Resolve each hunk.** Preserve both intents where possible. Where incompatible, pick the one matching the merge's stated goal and note the trade-off. Do **not** invent new behaviour.

4. Discover the project's **automated checks** and run them — typically typecheck, then tests, then format. Fix anything the merge broke.

5. **Finish the merge/rebase.** Stage everything and commit. If rebasing, continue the rebase process until all commits are rebased.
