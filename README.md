# project-home

The plugin half of **Project Home**: one plugin install, one command, and a new
project begins. Pairs with
[project-home-template](https://github.com/jdpretzel/project-home-template), the
repo template that `/new-project` seeds new projects from.

Carries the full skill set forked from upstream (see below) plus Project Home's
own machinery — model routing defaults, the lexicon system, Codex integration,
and the `/new-project` wrapper — as those land.

## Install

```bash
claude plugin marketplace add jdpretzel/project-home
claude plugin install project-home
```

## Status

Charting. Decisions are tracked as a wayfinder map in this repo's issues — look
for the `wayfinder:map` label.

## Attribution

Forked from [mattpocock/skills](https://github.com/mattpocock/skills) at commit
[`e9fcdf95b402d360f90f1db8d776d5dd450f9234`](https://github.com/mattpocock/skills/commit/e9fcdf95b402d360f90f1db8d776d5dd450f9234)
(plugin version 1.2.0-dev, 2026-07-14). MIT, © 2026 Matt Pocock — the original
[LICENSE](LICENSE) notice is kept intact, and the upstream README is preserved
as [UPSTREAM-README.md](UPSTREAM-README.md). That commit SHA is the anchor for
any future diff against upstream.
