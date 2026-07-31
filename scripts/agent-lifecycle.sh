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
    echo "main"
  fi
}

base_record_path() {
  echo "$(git rev-parse --absolute-git-dir)/agent-base"
}

recorded_base() {
  local record
  record="$(base_record_path)"
  if [ -f "$record" ]; then
    cat "$record"
  else
    echo "unrecorded"
  fi
}

fetch_or_fail() {
  # The credential helper may print "failed to store" noise on public
  # remotes; only the fetch's own exit status decides success.
  local out status=0
  out="$(git fetch "$REMOTE" 2>&1)" || status=$?
  printf '%s\n' "$out" | grep -v '^failed to store' >&2 || true
  [ "$status" -eq 0 ] || fail "fetch from '$REMOTE' failed (exit $status).
New mutating work must not start from a cached or local base. Retry when the
remote is reachable, or pass an explicit offline base with:
  scripts/agent-lifecycle.sh start <branch> --offline-base <commit-sha>"
}

cmd_preflight() {
  local brief=0
  [ "${1:-}" = "--brief" ] && brief=1

  local root branch head dirty untracked kind def def_tip fetch_age
  root="$(repo_root)"
  branch="$(git branch --show-current)"
  [ -n "$branch" ] || branch="(detached)"
  head="$(git rev-parse --short HEAD)"
  dirty="$(git status --porcelain | grep -cv '^??' || true)"
  untracked="$(git status --porcelain | grep -c '^??' || true)"
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
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir)"
  if [ -f "$common/FETCH_HEAD" ]; then
    fetch_age="$(stat -f '%Sm' "$common/FETCH_HEAD" 2>/dev/null || stat -c '%y' "$common/FETCH_HEAD" 2>/dev/null || echo unknown)"
    echo "last fetch: $fetch_age"
  else
    echo "last fetch: never"
  fi
  git worktree list
}

cmd_start() {
  local branch="" dir="" offline_base="" base_ref=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --base) base_ref="$2"; shift 2 ;;
      --offline-base) offline_base="$2"; shift 2 ;;
      -*) fail "unknown option '$1'" ;;
      *) [ -z "$branch" ] || fail "unexpected argument '$1'"; branch="$1"; shift ;;
    esac
  done
  [ -n "$branch" ] || fail "usage: scripts/agent-lifecycle.sh start <branch> [--base <remote-branch>] [--dir <path>] [--offline-base <sha>]"

  git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null && \
    fail "branch '$branch' already exists; choose a new name or enter its existing worktree"

  local base_sha base_desc
  if [ -n "$offline_base" ]; then
    base_sha="$(git rev-parse --verify --quiet "$offline_base^{commit}")" || \
      fail "offline base '$offline_base' does not resolve to a commit"
    base_desc="explicit offline base (no fetch — operator's choice)"
  else
    fetch_or_fail
    local ref="${base_ref:-$(default_branch)}"
    base_sha="$(git rev-parse --verify --quiet "refs/remotes/$REMOTE/$ref^{commit}")" || \
      fail "'$REMOTE/$ref' does not resolve after fetch; name the base with --base <remote-branch>"
    base_desc="$REMOTE/$ref, fetched in this start operation"
  fi

  if [ -z "$dir" ]; then
    local primary parent name
    primary="$(primary_root)"
    parent="$(dirname "$primary")"
    name="$(basename "$primary")"
    dir="$parent/$name-worktrees/$branch"
  fi
  [ ! -e "$dir" ] || fail "worktree path '$dir' already exists"
  mkdir -p "$(dirname "$dir")"

  git worktree add --no-track -b "$branch" "$dir" "$base_sha" >/dev/null
  git -C "$dir" rev-parse --absolute-git-dir >/dev/null || fail "worktree creation could not be verified"
  echo "$base_sha" > "$(git -C "$dir" rev-parse --absolute-git-dir)/agent-base"

  echo "worktree: $dir"
  echo "branch:   $branch"
  echo "base:     $base_sha ($base_desc)"
  echo "next:     cd '$dir' — plan there, recording this base commit, the intended"
  echo "          scope, and the publication endpoint before editing anything."
}

cmd_status() {
  is_primary_checkout && echo "note: this is the primary checkout, inspect-only for agents"
  local def
  def="$(default_branch)"
  echo "branch:   $(git branch --show-current || echo '(detached)') @ $(git rev-parse HEAD)"
  echo "base:     $(recorded_base)"
  echo "$REMOTE/$def: $(git rev-parse "refs/remotes/$REMOTE/$def" 2>/dev/null || echo unknown) (as of last fetch)"
  if [ -n "$(git status --porcelain)" ]; then
    git status --porcelain | sed 's/^/dirty:    /'
  else
    echo "tree:     clean"
  fi
}

cmd_publish_check() {
  is_primary_checkout && fail "publish-check runs inside the task's worktree, not the primary checkout"

  local failed=0
  fetch_or_fail

  local branch def
  branch="$(git branch --show-current)"
  def="$(default_branch)"
  [ -n "$branch" ] || { echo "FAIL: detached HEAD; publication needs a topic branch" >&2; failed=1; }
  [ "$branch" != "$def" ] || { echo "FAIL: on the default branch '$def'; publication uses a topic branch" >&2; failed=1; }

  if [ -n "$(git status --porcelain)" ]; then
    echo "FAIL: working tree not clean — the review and the push would disagree:" >&2
    git status --porcelain >&2
    failed=1
  fi

  local base cur_def
  base="$(recorded_base)"
  cur_def="$(git rev-parse "refs/remotes/$REMOTE/$def")"
  if [ "$base" != "unrecorded" ] && [ "$base" != "$cur_def" ] && git merge-base --is-ancestor "$base" "$cur_def"; then
    echo "ADVANCED: $REMOTE/$def moved from the recorded base $base to $cur_def."
    echo "          Decide before publishing: rebase (only if this branch is unpublished and"
    echo "          privately owned) or merge $REMOTE/$def into it (once published/shared)."
  fi

  echo "outgoing commits ($REMOTE/$def..HEAD):"
  git log --oneline "refs/remotes/$REMOTE/$def..HEAD" | sed 's/^/  /'

  local authority
  authority="$(git diff --name-only "$(git merge-base "refs/remotes/$REMOTE/$def" HEAD)"...HEAD | \
    grep -E '^(\.claude/|\.codex/|\.github/|\.claude-plugin/|scripts/agent-lifecycle)' || true)"
  if [ -n "$authority" ]; then
    echo "ATTENDED: this range changes authority-carrying paths:" >&2
    echo "$authority" | sed 's/^/  /' >&2
    echo "Owner approval is required before this branch's first push." >&2
    exit 3
  fi

  [ "$failed" -eq 0 ] || exit 1

  echo "publishable. Next, in order:"
  echo "  1. git push $REMOTE HEAD        (one topic ref; never --force)"
  echo "  2. open a draft PR onto '$def' immediately, then verify the remote head"
  echo "     and the PR's base/head"
  echo "  3. pause — merge is an owner decision"
}

cmd_close() {
  local target="${1:-}"

  if [ -z "$target" ]; then
    is_primary_checkout && fail "usage from the primary checkout: scripts/agent-lifecycle.sh close <worktree-path>"
    run_close_proofs "$(repo_root)"
    echo "proofs pass. A worktree cannot remove itself; from the primary checkout run:"
    echo "  scripts/agent-lifecycle.sh close $(repo_root)"
    return 0
  fi

  git worktree list --porcelain | grep -qx "worktree $target" || \
    fail "'$target' is not a registered worktree of this repository"
  [ "$target" != "$(primary_root)" ] || fail "refusing to operate on the primary checkout"

  run_close_proofs "$target"
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
  local wt="$1"
  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    git -C "$wt" status --porcelain >&2
    fail "worktree '$wt' has uncommitted or untracked work; cleanup would lose it"
  fi
  if [ -z "$(git -C "$wt" branch -r --contains HEAD)" ]; then
    fail "HEAD of '$wt' is not reachable from any remote branch; push it (or confirm it landed) before cleanup"
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
