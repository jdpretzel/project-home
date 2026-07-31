# 4. One agent repository lifecycle, owned by a deterministic script

Date: 2026-07-31

## Status

Accepted.

## Context

An incident bypassed `/implement` and worked from a stale local base in the
primary checkout — the one fresh-base rule lived on line 7 of a user-invoked
skill, so no instruction reached the path actually taken. The 2026-07-31
lifecycle governance research (preserved on the
`codex/governance-lifecycle-research` branch) audited Git semantics, Claude
Code and Codex hook contracts, this repository, and the live configuration,
and found the same structural gap everywhere: mutating work is reachable from
many skills and direct requests, but start, isolation, review scope,
publication, and cleanup had no owner.

## Decision

One lifecycle, three layers, one owner per fact:

- **`scripts/agent-lifecycle.sh`** owns the Git mechanics. `start` fetches
  `origin` (failing closed — an unresolvable remote base stops mutating work;
  `--offline-base <sha>` is an explicit operator choice, never a silent
  fallback), resolves the remote default branch (or `--base`) to an exact
  commit, creates an isolated worktree there, and records the base object ID
  in the worktree's gitdir. `publish-check` re-fetches, requires a clean tree
  and a non-default topic branch, exposes base advancement, and exits
  specially on authority-carrying paths. `close` removes a worktree only
  after proving there is no dirty, untracked, or remote-unreachable work —
  never with `--force`.
- **Thin harness adapters** register the same policy in both harnesses:
  `.claude/settings.json` and `.codex/hooks.json` run
  `scripts/agent-lifecycle.sh preflight --brief` on `SessionStart` (visible
  facts only — Claude documents SessionStart as context-adding, not
  blocking, so the hard gate lives at `PreToolUse`) and
  `scripts/agent-lifecycle-guard.py` on `PreToolUse` (exit 2 blocks in both).
  The guard denies only high-confidence violations — file edits and mutating
  git commands in the primary checkout, force pushes, forced worktree
  removal — and every denial states the fact, the rule, and the exact safe
  next action. Configuration files stay separate per harness; the executable
  policy is shared.
- **GitHub's `main-protections` ruleset** remains the landing authority (PR
  required, no force-push, no deletion, owner bound). Nothing client-side
  claims to replace it.

**Publication.** The blanket prohibition on unattended pushes is retired.
After review, an agent may unattended: push exactly one ordinary, non-default
topic branch (never force), immediately open a draft PR, verify the remote
head and the PR base/head, and pause for merge approval. Owner approval is
required for merge/auto-merge, force-push, rewriting published or shared
history, default-branch pushes, tags, releases, deployment, protection
bypasses, repository-setting changes, and unattended installs. A range that
changes authority-carrying paths (`.claude/`, `.codex/`, `.github/`,
`.claude-plugin/`, the lifecycle scripts) needs owner approval before its
first push — such a change alters what a push *does*, which no content review
proves safe.

**Base movement.** Rebase only an unpublished, privately owned branch. Once
published or shared, merge the current remote base into it; published history
is never rewritten. This decides the merge-style question issue #9 deferred;
branch naming stays unconstrained.

**Conflicts.** "Always resolve; never `--abort`" is retracted. Identify the
operation, checkout, intended base and head, pre-operation cleanliness, and
authority first; aborting is the correct outcome when the operation is
accidental, unauthorized, based on the wrong branch, or on top of unrelated
dirty work.

## Claude and Codex parity

Both harnesses document `SessionStart` and `PreToolUse` with compatible
JSON-on-stdin input and the exit-2-blocks-with-stderr-reason contract for
`PreToolUse` (Claude: https://code.claude.com/docs/en/hooks; Codex:
https://learn.chatgpt.com/docs/hooks — both retrieved 2026-07-31), so both
registrations share one guard with no translation layer. Known coverage gaps, recorded rather than papered over:

- Codex has no `WorktreeCreate`/`WorktreeRemove` equivalents. Codex-managed
  worktrees plus this lifecycle's `start`/`close` procedures are the fallback;
  no parity is claimed.
- Codex hook commands here use repo-relative paths (Codex documents no
  project-dir variable); a session started outside the repo root would not
  find them. Claude registrations use `$CLAUDE_PROJECT_DIR`.
- Hooks see model tool calls, not native app/hosted operations, and the
  matchers do not cover MCP tools that can mutate GitHub state.
- The guard deliberately does not parse raw shell writes (redirection,
  `sed -i`) in the primary checkout, to keep false positives near zero.

All of this is mistake prevention for agents. Repo-owned, model-writable
hooks are not an adversarial security boundary; the stronger boundary stays
with GitHub's ruleset and user/managed-scope configuration.

## Superseded and out of scope

Superseded by this decision: the missing universal lifecycle entry (the rule
now lives in `CLAUDE.md`, always-on for both harnesses via the `AGENTS.md`
symlink); "fresh" meaning anything other than a successful fetch in this
start operation; the unconditional never-abort rule; and the blanket no-push
boundary, replaced by the narrow topic-branch-to-draft-PR authority above.
Issue #9's rejection of the blanket `misc/` git-guardrail stands — this
design blocks a handful of exact conditions and returns the safe path, it
does not wall off pushes.

Deliberately not absorbed here: the router-enforcement mechanism (#13), the
docs upstream-frame defect (#19), promoted-only skill linking (#29/PR #31
territory), and any custom publication helper — native `git push` plus a
draft PR is the path until a focused trial against valid authentication
demonstrates a specific unsatisfied requirement.
