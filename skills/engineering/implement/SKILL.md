---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Fetch first — a stale default branch hides merged blockers — then start on a new branch off the default branch, or off the integration branch when the ticket names one. Don't start a ticket until its blockers have merged; independent tickets can run in parallel.

Implement the work described by the user in the spec or tickets.

Use /tdd where possible, at the seams the spec or tickets name. If something couldn't be red-greened, say so and how you verified it instead.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, commit; where the work has a ticket, reference it in the commit message (on GitHub, `Closes #<n>`) — that reference is how /code-review finds the spec. The commit is the checkpoint that makes review possible: /code-review reads committed history, not the working tree.

Run /code-review with the branch's base as the fixed point, and address what it finds in narrow fix-up commits. If those fixes are substantive, re-run the full test suite and review again; if they're narrow, re-run the tests that cover them and record that verification.

Push and open the PR against the base without asking; if the repo has no remote, stop at the reviewed branch and report it ready to merge. Either way, stop there — never merge without the owner's explicit approval.
