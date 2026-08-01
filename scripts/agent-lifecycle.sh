#!/usr/bin/env bash
set -euo pipefail

# The deterministic owner of the agent repository lifecycle's Git mechanics
# (ADR 0004). Subcommands:
#
#   preflight [--brief]      read-only state snapshot; never mutates
#   start <branch> [opts]    fetch, resolve the exact remote base commit,
#                            create an isolated worktree there, record the base
#   status                   in-worktree summary against the recorded base
#   publish-check            re-fetch, prove publishable state, expose base
#                            advancement, stop on authority-changing paths
#   close [<path>]           prove nothing is lost, then remove the worktree
#
# Every mutating agent task enters through `start`; the primary checkout is
# inspect-only. Hooks in .claude/settings.json and .codex/hooks.json advise on
# session start and block primary-checkout mutation; this script is the one
# source of the Git semantics they defer to.

REMOTE="origin"

fail() {
  echo "error: $*" >&2
  exit 1
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || fail "not inside a git repository"
}

# The primary checkout is the one whose .git is a directory; worktrees carry a
# .git file pointing back at it.
primary_root() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir)"
  dirname "$common"
}

is_primary_checkout() {
  [ "$(repo_root)" = "$(primary_root)" ]
}

default_branch() {
  local ref
  if ref="$(git symbolic-ref --quiet "refs/remotes/$REMOTE/HEAD" 2>/dev/null)"; then
    echo "${ref#refs/remotes/$REMOTE/}"
  else
    echo "note: refs/remotes/$REMOTE/HEAD is unset; assuming default branch 'main'" >&2
    echo "main"
  fi
}

base_record_path() {
  echo "$(git rev-parse --absolute-git-dir)/agent-base"
}

# The record file holds "<sha> <remote-branch>"; older or hand-made records
# may hold the sha alone.
recorded_base() {
  local record
  record="$(base_record_path)"
  if [ -f "$record" ]; then
    awk '{print $1; exit}' "$record"
  else
    echo "unrecorded"
  fi
}

recorded_base_ref() {
  local record ref
  record="$(base_record_path)"
  ref=""
  [ -f "$record" ] && ref="$(awk '{print $2; exit}' "$record")"
  if [ -n "$ref" ]; then
    echo "$ref"
  else
    default_branch
  fi
}

fetch_or_fail() {
  # The credential helper may print "failed to store" noise on public
  # remotes; only the fetch's own exit status decides success.
  local out status=0
  # --prune: a remote-tracking ref the remote no longer advertises is stale
  # evidence — it must not resolve a base or vouch for reachability.
  out="$(git fetch --prune "$REMOTE" 2>&1)" || status=$?
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | grep -v '^failed to store' >&2 || true
  fi
  [ "$status" -eq 0 ] || fail "fetch from '$REMOTE' failed (exit $status).
New mutating work must not start from a cached or local base. Retry when the
remote is reachable. (--offline-base <sha> exists for the owner's explicit
offline decision; do not choose it unattended.)"
}

cmd_preflight() {
  local brief=0
  if [ $# -gt 0 ]; then
    [ "$1" = "--brief" ] || fail "unknown option '$1' (usage: preflight [--brief])"
    brief=1
  fi

  local root branch head porcelain dirty untracked kind def def_tip fetch_age
  root="$(repo_root)"
  branch="$(git branch --show-current)"
  [ -n "$branch" ] || branch="(detached)"
  head="$(git rev-parse --short HEAD)"
  porcelain="$(git status --porcelain --untracked-files=all)" || fail "git status failed; state unknown"
  dirty="$(printf '%s' "$porcelain" | grep -cv '^??' || true)"
  untracked="$(printf '%s' "$porcelain" | grep -c '^??' || true)"
  if is_primary_checkout; then kind="primary checkout (inspect-only for agents)"; else kind="isolated worktree"; fi
  def="$(default_branch)"
  def_tip="$(git rev-parse --short "refs/remotes/$REMOTE/$def" 2>/dev/null || echo "unknown")"

  echo "lifecycle: $kind | branch $branch @ $head | $dirty modified, $untracked untracked"
  echo "lifecycle: $REMOTE/$def @ $def_tip (from last fetch; not fetched now) | base $(recorded_base)"
  if [ "$brief" -eq 1 ]; then
    if is_primary_checkout; then
      echo "lifecycle: mutating work starts with: scripts/agent-lifecycle.sh start <branch>"
    fi
    return 0
  fi

  echo "root: $root"
  echo "primary: $(primary_root)"
  local fetch_head
  fetch_head="$(git rev-parse --git-path FETCH_HEAD)"
  if [ -f "$fetch_head" ]; then
    # Chained assignments, not one substitution: on GNU, `stat -f` means
    # filesystem status, so the BSD probe can print a report to stdout and
    # still fail — its output must be discarded, not concatenated.
    fetch_age="$(stat -f '%Sm' "$fetch_head" 2>/dev/null)" || \
      fetch_age="$(stat -c '%y' "$fetch_head" 2>/dev/null)" || \
      fetch_age=unknown
    echo "last fetch: $fetch_age"
  else
    echo "last fetch: never (in this checkout)"
  fi
  git worktree list
}

cmd_start() {
  local branch="" dir="" offline_base="" base_ref=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir|--base|--offline-base)
        [ $# -ge 2 ] || fail "option '$1' requires a value"
        case "$1" in
          --dir) dir="$2" ;;
          --base) base_ref="$2" ;;
          --offline-base) offline_base="$2" ;;
        esac
        shift 2 ;;
      -*) fail "unknown option '$1'" ;;
      *) [ -z "$branch" ] || fail "unexpected argument '$1'"; branch="$1"; shift ;;
    esac
  done
  [ -n "$branch" ] || fail "usage: scripts/agent-lifecycle.sh start <branch> [--base <remote-branch>] [--dir <path>] [--offline-base <sha>]"

  git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null && \
    fail "branch '$branch' already exists; choose a new name or enter its existing worktree"

  local base_sha base_desc record_ref=""
  if [ -n "$offline_base" ]; then
    base_sha="$(git rev-parse --verify --quiet "$offline_base^{commit}")" || \
      fail "offline base '$offline_base' does not resolve to a commit"
    base_desc="explicit offline base (no fetch — the owner's choice, not a default)"
    # An owner who also names --base still means that branch as the
    # publication target; dropping it would point publish-check at the
    # default branch.
    record_ref="$base_ref"
  else
    fetch_or_fail
    # Fetch does not refresh the cached notion of the remote's default
    # branch; re-ask the remote so a renamed default cannot mislead us.
    # When the answer is the base (no --base), a failed refresh fails the
    # start: continuing on the cached name could base the task on a former
    # default branch while claiming to have resolved the current one.
    if [ -z "$base_ref" ]; then
      git remote set-head "$REMOTE" --auto >/dev/null 2>&1 || \
        fail "could not refresh $REMOTE/HEAD, so the current default branch is
unknown and the cached name may be stale. Retry when the remote can answer,
or name the base explicitly with --base <remote-branch>."
    fi
    local ref="${base_ref:-$(default_branch)}"
    base_sha="$(git rev-parse --verify --quiet "refs/remotes/$REMOTE/$ref^{commit}")" || \
      fail "'$REMOTE/$ref' does not resolve after fetch; name the base with --base <remote-branch>"
    base_desc="$REMOTE/$ref, fetched in this start operation"
    record_ref="$ref"
  fi

  # A remote branch of the same name means the later `git push origin HEAD`
  # would append this task to someone's published branch — or fail only
  # after the work is done. (In --offline-base mode this checks the cached
  # remote-tracking refs, the best evidence available without a fetch.)
  git rev-parse --verify --quiet "refs/remotes/$REMOTE/$branch" >/dev/null && \
    fail "'$REMOTE/$branch' already exists; choose a new branch name, or ask the owner about the published one"

  if [ -z "$dir" ]; then
    local primary parent name
    primary="$(primary_root)"
    parent="$(dirname "$primary")"
    name="$(basename "$primary")"
    dir="$parent/$name-worktrees/$branch"
  fi
  # A worktree inside the primary checkout would leave the primary holding
  # untracked mutable state — no longer inspect-only. Resolve the deepest
  # existing ancestor physically before comparing, so symlinks cannot hide
  # the nesting.
  local abs_dir walk suffix=""
  abs_dir="$dir"
  [ "${abs_dir#/}" != "$abs_dir" ] || abs_dir="$PWD/$abs_dir"
  walk="$abs_dir"
  while [ ! -d "$walk" ] && [ "$walk" != "/" ]; do
    suffix="/$(basename "$walk")$suffix"
    walk="$(dirname "$walk")"
  done
  walk="$(cd "$walk" && pwd -P)$suffix"
  case "$walk/" in
    "$(primary_root)"/*) fail "worktree path '$dir' is inside the primary checkout; place worktrees outside it (default: a sibling <name>-worktrees directory)" ;;
  esac

  [ ! -e "$dir" ] || fail "worktree path '$dir' already exists"
  mkdir -p "$(dirname "$dir")"

  git worktree add --no-track -b "$branch" "$dir" "$base_sha" >/dev/null
  git -C "$dir" rev-parse --absolute-git-dir >/dev/null || fail "worktree creation could not be verified"
  echo "$base_sha${record_ref:+ $record_ref}" > "$(git -C "$dir" rev-parse --absolute-git-dir)/agent-base"

  echo "worktree: $dir"
  echo "branch:   $branch"
  echo "base:     $base_sha ($base_desc)"
  echo "next:     cd '$dir' — plan there, recording this base commit, the intended"
  echo "          scope, and the publication endpoint before editing anything."
}

cmd_status() {
  is_primary_checkout && echo "note: this is the primary checkout, inspect-only for agents"
  local def branch
  def="$(default_branch)"
  branch="$(git branch --show-current)"
  [ -n "$branch" ] || branch="(detached)"
  echo "branch:   $branch @ $(git rev-parse HEAD)"
  echo "base:     $(recorded_base)"
  echo "$REMOTE/$def: $(git rev-parse "refs/remotes/$REMOTE/$def" 2>/dev/null || echo unknown) (as of last fetch)"
  if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    git status --porcelain --untracked-files=all | sed 's/^/dirty:    /'
  else
    echo "tree:     clean"
  fi
}

cmd_publish_check() {
  is_primary_checkout && fail "publish-check runs inside the task's worktree, not the primary checkout"

  local failed=0
  fetch_or_fail

  # The publication target is the branch this task was started from — the
  # default branch normally, the recorded --base ref when the ticket named
  # an integration branch.
  local branch dest
  branch="$(git branch --show-current)"
  dest="$(recorded_base_ref)"
  [ -n "$branch" ] || { echo "FAIL: detached HEAD; publication needs a topic branch" >&2; failed=1; }
  [ "$branch" != "$dest" ] || { echo "FAIL: on the target branch '$dest' itself; publication uses a topic branch" >&2; failed=1; }
  [ "$branch" != "$(default_branch)" ] || { echo "FAIL: on the default branch; publication uses a topic branch" >&2; failed=1; }

  if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    echo "FAIL: working tree not clean — the review and the push would disagree:" >&2
    git status --porcelain --untracked-files=all >&2
    failed=1
  fi

  local base cur_dest
  base="$(recorded_base)"
  cur_dest="$(git rev-parse "refs/remotes/$REMOTE/$dest")" || \
    fail "'$REMOTE/$dest' does not resolve; the recorded target branch is gone — owner decision needed"
  if [ "$base" = "unrecorded" ]; then
    echo "WARNING: no recorded base — this worktree was not created by 'start'." >&2
    echo "         Verify yourself that the branch began from a fetched $REMOTE/$dest." >&2
  elif ! git merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
    echo "note: the recorded base $base is not an ancestor of HEAD (rebased, or the"
    echo "      wrong worktree?). Verify the intended base before publishing."
  fi
  if [ "$base" != "unrecorded" ] && [ "$base" != "$cur_dest" ]; then
    if git merge-base --is-ancestor "$base" "$cur_dest" 2>/dev/null; then
      echo "ADVANCED: $REMOTE/$dest moved from the recorded base $base to $cur_dest."
      echo "          Decide before publishing: rebase (only if this branch is unpublished and"
      echo "          privately owned) or merge $REMOTE/$dest into it (once published/shared)."
    else
      echo "DIVERGED: the recorded base $base is no longer an ancestor of $REMOTE/$dest" >&2
      echo "          ($cur_dest). The target branch history changed under this task;" >&2
      echo "          stop and get an owner decision before publishing." >&2
      failed=1
    fi
  fi

  echo "outgoing commits ($REMOTE/$dest..HEAD):"
  git log --oneline "refs/remotes/$REMOTE/$dest..HEAD" | sed 's/^/  /'

  [ "$failed" -eq 0 ] || exit 1

  # --no-renames: a rename would otherwise list only its destination, letting
  # `git mv .claude/settings.json elsewhere` slip past the gate.
  local merge_base authority
  merge_base="$(git merge-base "refs/remotes/$REMOTE/$dest" HEAD)" || \
    fail "no merge base with $REMOTE/$dest; cannot classify the outgoing range"
  # CLAUDE.md/AGENTS.md match at any depth: both harnesses read nested
  # per-directory instruction files, so a scoped one governs its subtree
  # with the same authority as the root file.
  authority="$(git diff --name-only --no-renames "$merge_base" HEAD | \
    grep -E '^(\.claude/|\.codex/|\.github/|\.claude-plugin/|scripts/agent-lifecycle)|(^|/)(CLAUDE|AGENTS)\.md$' || true)"
  if [ -n "$authority" ]; then
    echo "ATTENDED: this range changes authority-carrying paths:" >&2
    echo "$authority" | sed 's/^/  /' >&2
    echo "Owner approval is required before this branch's first push." >&2
    exit 3
  fi

  echo "publishable. Next, in order:"
  echo "  1. git push $REMOTE HEAD        (one topic ref; never --force)"
  echo "  2. open a draft PR onto '$dest' immediately, then verify the remote head"
  echo "     and the PR's base/head"
  echo "  3. pause — merge is an owner decision"
}

cmd_close() {
  local target="" delete_ignored=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --delete-ignored) delete_ignored=1; shift ;;
      -*) fail "unknown option '$1' (usage: close [<worktree-path>] [--delete-ignored])" ;;
      *) [ -z "$target" ] || fail "unexpected argument '$1'"; target="$1"; shift ;;
    esac
  done

  if [ -z "$target" ]; then
    is_primary_checkout && fail "usage from the primary checkout: scripts/agent-lifecycle.sh close <worktree-path>"
    run_close_proofs "$(repo_root)" "$delete_ignored"
    echo "proofs pass. A worktree cannot remove itself; from the primary checkout run:"
    echo "  scripts/agent-lifecycle.sh close $(repo_root)"
    return 0
  fi

  # Normalize before comparing with git's realpath'd registry (e.g. the
  # macOS $TMPDIR spelling of a /private/tmp worktree).
  target="$(cd "$target" 2>/dev/null && pwd -P)" || \
    fail "worktree path does not exist or is not a directory"
  local registry
  registry="$(git worktree list --porcelain)"
  printf '%s\n' "$registry" | grep -qxF "worktree $target" || \
    fail "'$target' is not a registered worktree of this repository — compare 'git worktree list'"
  [ "$target" != "$(primary_root)" ] || fail "refusing to operate on the primary checkout"

  run_close_proofs "$target" "$delete_ignored"
  local branch
  branch="$(git -C "$target" branch --show-current)"
  git worktree remove "$target"
  echo "removed: $target (ordinary removal; --force is never used)"
  # An `if`, not `&&`: a detached-HEAD worktree has no branch to report, and a
  # trailing false test would make a successful close exit nonzero — a caller
  # would read that as "cleanup failed" and reach for force.
  if [ -n "$branch" ]; then
    echo "branch '$branch' kept; delete with 'git branch -d $branch' once merged."
  fi
}

run_close_proofs() {
  local wt="$1" delete_ignored="${2:-0}"
  # --untracked-files=all on every proof-bearing status: a repository or
  # user setting of status.showUntrackedFiles=no would otherwise hide
  # exactly the files the no-loss proof exists to protect.
  if [ -n "$(git -C "$wt" status --porcelain --untracked-files=all)" ]; then
    git -C "$wt" status --porcelain --untracked-files=all >&2
    fail "worktree '$wt' has uncommitted or untracked work; cleanup would lose it"
  fi
  # Ignored files pass the plain porcelain proof but are destroyed with the
  # worktree (.env files, scratch notes, local test data).
  local ignored
  ignored="$(git -C "$wt" status --porcelain --ignored --untracked-files=all | grep '^!!' || true)"
  if [ -n "$ignored" ] && [ "$delete_ignored" -ne 1 ]; then
    printf '%s\n' "$ignored" >&2
    fail "worktree '$wt' contains ignored files that removal would delete.
Move them out first, or re-run with --delete-ignored to accept their deletion"
  fi
  # Judge reachability against freshly fetched remote refs, not a stale
  # remote-tracking cache; --prune so a branch the remote has deleted or
  # force-moved cannot vouch for HEAD. An unreachable remote fails closed.
  local out status=0
  out="$(git -C "$wt" fetch --prune "$REMOTE" 2>&1)" || status=$?
  [ "$status" -eq 0 ] || { printf '%s\n' "$out" >&2; \
    fail "fetch from '$REMOTE' failed; cannot prove HEAD is published, refusing cleanup"; }
  if [ -z "$(git -C "$wt" branch -r --contains HEAD)" ]; then
    fail "HEAD of '$wt' is not reachable from any remote branch (checked after a fresh fetch); push it (or confirm it landed) before cleanup"
  fi
}

case "${1:-}" in
  preflight) shift; cmd_preflight "$@" ;;
  start) shift; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  publish-check) shift; cmd_publish_check "$@" ;;
  close) shift; cmd_close "$@" ;;
  *) fail "usage: scripts/agent-lifecycle.sh {preflight|start|status|publish-check|close} — see ADR 0004" ;;
esac
