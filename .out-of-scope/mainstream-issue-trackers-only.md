# GitHub is the only supported issue tracker

Requests to add support for another issue tracker — GitLab, Jira, Linear, Backlog.md, a local-markdown convention, or anything newer — are out of scope.

## Why this is out of scope

This was once a narrower rule: support the *mainstream* trackers, reject the niche ones, and point everyone else at the `local markdown` or `other/custom` escape hatches. That position is gone. The tracker-kind choice, the generated tracker config, the provider templates, and the escape hatches were all removed — see [ADR 0003](../.agents/adr/0003-github-is-the-supported-tracker.md).

The reasoning that killed the narrower rule kills the broader one too, and more decisively. Every backend hard-codes a CLI shape into the skills — commands, flags, output parsing — and each one is permanent maintenance surface that has to keep working as that tool's CLI evolves and keep being tested against `/to-spec`, `/to-tickets`, `/triage`, and `/wayfinder`. The indirection built to make that cost bearable turned out to cost more than it saved for a set of skills whose operator uses GitHub for everything: a config file required in every repo before five skills would work, three templates to keep in sync, and a silent fallback that answered confidently and wrongly when the config was missing.

So the answer to "please support tracker X" is no, and it isn't a judgement call about how mainstream X is any more.

## What would reopen it

A second tracker becoming an **actual requirement** — not an anticipated one. At that point the right move is to extract a provider seam deliberately, informed by two real cases rather than one real case and a guess. Until then, adding one back means restoring the whole mechanism this repo removed on purpose.

## Prior requests

- #99 — "Add dex as an issue tracker backend" (dex was ~3 months old and ~300 stars at the time of the request). Rejected then for being non-mainstream; would be rejected now regardless of how mainstream it became.
