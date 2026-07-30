# Explicit `/setup-project-home` pointer only for hard dependencies

Engineering skills depend on per-repo config (issue tracker, triage label vocabulary, domain doc layout) seeded by `/setup-project-home`. Some skills cannot meaningfully function without that config — they have to publish to a specific issue tracker or apply a specific label string. Others only use it to sharpen output (vocabulary, ADR awareness) and degrade gracefully without it.

We split these into **hard-dependency** and **soft-dependency** skills:

- **Hard dependency** (`to-tickets`, `to-spec`, `triage`) — include an explicit one-liner: _"… should have been provided to you — run `/setup-project-home` if not."_ Without the mapping, output is wrong, not just fuzzy.
- **Soft dependency** (`diagnose`, `tdd`, `improve-codebase-architecture`) — reference "the project's domain glossary" and "ADRs in the area you're touching" in vague prose only. If the docs aren't there, the skill still works; output is just less sharp.

The split keeps soft-dependency skills token-light and avoids cargo-culting the setup pointer into places where it isn't load-bearing.

## Superseded in part by [ADR 0003](./0003-github-is-the-supported-tracker.md)

The **issue tracker** is no longer per-repo config: GitHub is the supported tracker, each skill carries its own GitHub behaviour, and `docs/agents/` no longer exists. So the tracker half of the hard-dependency case is gone — `wayfinder`, `to-spec`, `to-tickets`, and `code-review` no longer need the pointer for it, and a missing GitHub repo is now a loud stop rather than something setup must have pre-supplied.

What survives, and what this ADR still governs: **triage label vocabulary** remains genuinely per-repo, so `triage`, `to-spec`, and `to-tickets` keep the explicit pointer for that. Domain docs remain a soft dependency, referenced in vague prose. The reasoning — an explicit pointer only where output would be *wrong* rather than merely fuzzy — is unchanged; only the list of things that qualify has shrunk.
