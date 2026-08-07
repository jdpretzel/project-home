# 5. Retire the guard's shell interpretation; keep the thin primary gate

Date: 2026-08-06

## Status

Accepted. Amends [ADR 0004](./0004-agent-repository-lifecycle.md): the
guard's six denial classes reduce to a location gate; everything else in
0004 — `start`, `publish-check`, `close`, the publication contract, the
GitHub ruleset as landing authority — stands unchanged.

## Context

ADR 0004's guard denied six classes of operation, four of which required
interpreting shell text: command segmentation, `cd`/environment/`-C`
tracking, runner peeling, and push/refspec analysis. Its first production
use (the issue-#19 docs fix) produced, within one working session, both
failure modes that interpretation risks:

- **A wrong block** — `git push origin HEAD 2>&1` denied as "multiple
  refspecs": the tokenizer split `2>&1` into stray tokens counted as
  refspecs (observed live 2026-08-02). The guard's own contract says a
  miss must be an allow, never a wrong block.
- **A bypass** — an unquoted command substitution resets the guard's
  directory tracking, so `echo $(date) && git commit` passes in the
  primary checkout (reproduced live 2026-08-04).

An independent platform survey reached the same conclusion — native
worktrees, harness sandboxes, and GitHub rulesets already own most of
what the parser attempted, and partial shell interpretation cannot be
made complete — while confirming that neither Claude's nor Codex's
native worktrees provide `start`'s fail-closed fresh-fetch guarantee.
The survey is preserved on the local `codex/simpler-governance-research`
branch (`.agents/research/2026-08-04-simpler-agent-lifecycle.md`, cited
sources retrieved 2026-08-04).

## Decision

Owner-directed, 2026-08-06:

- **Remove the shell-command parser** and all push/refspec/redirection
  interpretation. The guard keeps exactly two denial classes: file-tool
  and `apply_patch` writes inside the primary checkout, and a direct
  `git <mutating-verb>` whose session cwd is inside the primary — a
  set-membership check on the verb. A command that names its own
  repository (`-C`, `--git-dir`, `--work-tree`, an environment prefix)
  fails open: resolving where it operates is the interpretation this
  decision removes.
- **Keep `start` unchanged.** The fail-closed fetch-and-create guarantee
  is the part native worktrees do not provide.
- **`close` is a safety helper, not an enforced exclusive path.** The
  guard's deny of every `git worktree remove` is dropped. Git itself
  refuses to remove a dirty worktree unforced; forced removal is
  prohibited in guidance. `close` remains the recommended remover
  because its proofs also cover unpushed commits and ignored files.
- **No GitHub ruleset expansion in this change.** `main` stays protected;
  topic branches are recoverable; tags and releases are owner actions by
  policy. All-branch and tag rules remain available hardening, adopted
  only if experience shows the need.
- **The unpublished `guard-redirection-tokens` branch (`81e369e`) is
  abandoned**: it fixed the tokenizer this decision deletes.

The retired denials are pinned as fail-opens in
`test_guard_deliberate_fail_opens`, which fails against the pre-decision
guard — the deletion is a decision, not an accident. What holds the line
now: worktree isolation, `close`'s loss proofs, GitHub's ruleset, and
owner review at the PR.

## Consequences

- Wrong blocks in the retired classes are impossible; misses fail open
  and are recoverable (remote, reflog, `git status` visibility).
- The guard drops from 565 to under 200 lines and no longer needs a
  per-spelling test matrix; the remaining suite pins the gate, the
  fail-opens, and the escape hatch.
- The publication contract (one topic branch, draft PR, owner merge) is
  now enforced socially and by GitHub, not client-side — which is where
  ADR 0004 already located the real boundary.
