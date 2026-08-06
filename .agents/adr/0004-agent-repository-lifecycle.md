# 4. One agent repository lifecycle, owned by a deterministic script

Date: 2026-07-31

## Status

Accepted. Amended by
[ADR 0005](./0005-retire-the-guards-shell-interpretation.md) (2026-08-06):
the guard's six denial classes are reduced to a thin primary-checkout
gate after production use produced both a wrong block and a bypass;
`start`, `publish-check`, `close`, the publication contract, and the
GitHub ruleset stand unchanged.

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
  `origin` (failing closed — an unresolvable remote base stops mutating
  work; `--offline-base <sha>` is the owner's explicit decision, never an
  agent's fallback; a `--dir` inside the primary checkout is refused —
  a nested worktree would end the primary's inspect-only state, pinned by
  `test_start_refuses_a_dir_inside_the_primary_checkout`), refreshes
  `origin/HEAD` so a renamed default branch
  cannot mislead — failing closed when the remote cannot answer and no
  `--base` was named, since continuing on the cached name could base the
  task on a former default (pinned by
  `test_start_fails_when_the_default_branch_cannot_be_refreshed`) —
  resolves the remote default branch (or `--base`) to an
  exact commit, refuses a topic name that already exists locally *or* on
  the remote (publishing would append to someone's published branch;
  pinned by `test_start_refuses_a_branch_already_on_the_remote`),
  creates an isolated worktree there, and records the base
  object ID *and* base ref in the worktree's gitdir — `publish-check` later
  targets that ref, so integration-branch work is not misdirected at the
  default branch. `publish-check` re-fetches, requires a clean tree and a
  non-target topic branch, exposes base advancement (and fails on base
  *divergence* — a rewritten target), warns when the base is unrecorded,
  and exits specially on authority-carrying paths. `close` removes a
  worktree only after proving — against a fresh *pruned* fetch (a
  remote-tracking ref the remote no longer advertises is stale evidence,
  so a deleted or force-moved remote branch cannot vouch for HEAD, and
  restricted to that remote's refs — another remote's stale tracking ref
  cannot vouch either (pinned by
  `test_close_refuses_after_the_remote_branch_was_deleted` and
  `test_close_ignores_other_remotes_tracking_refs`)),
  failing closed if the fetch fails — that there is no dirty, untracked,
  ignored-but-present (without `--delete-ignored`), or remote-unreachable
  work; never with `--force`. Every proof-bearing status forces
  `--untracked-files=all`, so `status.showUntrackedFiles=no` in any
  configuration scope cannot hide the files the proof protects (pinned by
  `test_close_proof_survives_hidden_untracked_config`). Verifying that the expected PR exists and landed is left to
  the operator or the GitHub layer: `gh` is not reliably runnable in the
  sandboxed sessions this repo measures, and a fresh-fetch reachability
  proof plus the kept branch bounds the loss to zero commits.
- **Thin harness adapters** register the same policy in both harnesses:
  `.claude/settings.json` and `.codex/hooks.json` run
  `scripts/agent-lifecycle.sh preflight --brief` on `SessionStart` (visible
  facts only — Claude documents SessionStart as context-adding, not
  blocking, so the hard gate lives at `PreToolUse`) and
  `scripts/agent-lifecycle-guard.py` on `PreToolUse` (exit 2 blocks in both;
  the registrations fail closed when `python3` is missing rather than
  silently disarming). The guard is a small footgun catch, not a command
  interpreter: it denies only operations that are both consequential and
  reliably detectable at the git-verb level. The denied set — file edits
  and mutating git verbs against the primary checkout, including via
  `-C`, `--git-dir`, a `GIT_DIR`/`GIT_WORK_TREE` environment prefix, a
  bare runner word (`command`, `nohup`, …), or a `cd` earlier in the
  command (a `cd` whose target cannot exist keeps the prior directory,
  since the shell does too — pinned in
  `test_guard_blocks_primary_checkout_mutation` and
  `test_guard_directory_tracking_and_runners`); writes to state every
  worktree shares with the primary — `config` writes (except `--worktree`
  scope outside the primary) and `remote` rewrites (pinned in
  `test_guard_blocks_shared_state_and_recovery_surgery` and
  `test_guard_shared_state_from_worktrees`); the recovery-destroyers —
  `reflog expire|delete` and `gc` against the primary, force, deleting,
  pruning, or mirror pushes anywhere, and every `git worktree remove`
  (only `close` runs the loss proofs, and even unforced removal deletes
  ignored files); pushes beyond the one-topic-branch contract — the
  remote default branch as destination in any spelling, `refs/tags/`
  destinations, `--all`/`--branches`/`--tags`/`--follow-tags`, or
  multiple refspecs in one push (all pinned in
  `test_guard_push_matrix`); and implicit-base `git worktree add` — and
  every denial states the fact, the rule, and the exact safe next
  action.
  Configuration files stay separate per harness; the executable policy is
  shared. In both harnesses a repo's hooks become active only after the
  owner has reviewed and trusted them in that harness (Claude: workspace
  trust for project settings; Codex: the documented hook review-and-trust
  step) — activation is a named checkpoint after landing, not something a
  clone gets automatically.
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
`.claude-plugin/`, the lifecycle scripts, and `CLAUDE.md`/`AGENTS.md` at
any directory depth — both harnesses read nested per-directory
instruction files, so a scoped one carries the same authority; pinned by
`test_publish_check_authority_gate_matches_nested_agents_md`) needs owner approval before its first push —
such a change alters what a push *does*, which no content review proves
safe.

**Production validation.** The unattended path — topic-branch push, draft
PR, pause, approved merge, landed-state verification, cleanup — has **not
yet run on a legitimate ordinary PR**. That live validation is the named
pending checkpoint: the next ordinary reviewed change completes it, and
until then the path is design-verified (tests and probes) only.

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
- Codex documents no project-dir variable, so its hook commands resolve the
  repo root themselves (`git rev-parse --show-toplevel`) before running the
  shared scripts, per Codex's own hooks guidance; Claude registrations use
  `$CLAUDE_PROJECT_DIR`.
- Hooks see model tool calls, not native app/hosted operations, and the
  matchers do not cover MCP tools that can mutate GitHub state.
- The guard deliberately fails open on everything outside its six denial
  classes — a miss must be an allow, never a wrong block, and partial
  coverage of arbitrary shell is worse than its honest absence. An earlier
  revision grew, under review pressure, toward a partial shell-command
  interpreter: plain-shell write analysis (`rm`/`cp`/`mv`/`sed -i`/
  `chmod`/`install`/`ln`/redirections), `clone` and `format-patch`
  destination checks, fetch-refspec analysis, `branch`/`tag`/`notes`/
  `bisect` subcommand disambiguation, unqualified-tag refspec resolution,
  and per-runner option parsing. That coverage was deleted on 2026-08-01
  by the owner's deletion test — retain only controls that are both
  consequential and reliably detectable — because every deleted class is
  local, recoverable damage (from the remote, the reflog, and plain
  `git status` visibility) while its detection was inherently incomplete
  (any interpreter, `python -c` upward, bypasses it). The deletion is
  pinned as behaviour, not accident: `test_guard_deliberate_fail_opens`
  asserts the guard *allows* representative deleted cases, and fails
  against the pre-deletion guard. The parsing gaps stay fail-open too:
  unparseable stdin, an undetectable primary root, unknown tool names, a
  payload without `cwd`, statically unresolvable `cd` targets, subshell
  and command-substitution contents, flagged runner invocations
  (`nice -n 10 …`), and unbalanced quotes. What keeps all of this safe is
  precisely the denied set: the guard blocks the commands that would
  destroy the recovery paths — `reflog expire`/`gc` against the primary
  (pinned in `test_guard_blocks_shared_state_and_recovery_surgery`) and
  ref-deleting or force pushes (pinned in `test_guard_push_matrix`).
- The doc-writing flows (`research`, `domain-modeling`, and
  `grill-with-docs`, which drives it) carry no per-skill lifecycle pointer:
  in this repo the always-on invariant and the hooks already route them,
  and in consumer repos their writes are notes and ADRs, not code — adding
  the pointer to every such skill is the procedure-duplication outcome 11
  of the contract forbids. Revisit if a doc-writing flow ever grows a
  code-mutating step.

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
