---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Start on a new branch off the default branch. Don't start a ticket until its blockers have merged; independent tickets can run in parallel.

Implement the work described by the user in the spec or tickets.

Use /tdd where possible, at the seams the spec or tickets name. If something couldn't be red-greened, say so and how you verified it instead.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, commit; where the work has a numbered ticket, use `Closes #<n>` — that trailer is how /code-review finds the spec. The commit is the checkpoint that makes review possible: /code-review reads committed history, not the working tree.

Run /code-review with the default branch as the fixed point, and address what it finds in narrow fix-up commits. If those fixes are substantive, review again; if they're narrow and you verified them directly, record that verification.

Push and open the PR without asking. Stop there — never merge without the owner's explicit approval.
