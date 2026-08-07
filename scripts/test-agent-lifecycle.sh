#!/usr/bin/env bash
set -euo pipefail

# Behavioural tests for the two files that own the agent repository lifecycle:
# scripts/agent-lifecycle.sh (the Git mechanics) and scripts/agent-lifecycle-guard.py
# (the PreToolUse guard). Fixtures are throwaway git repositories under a mktemp
# root; every "remote" is a file path, so nothing here touches the network.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIFECYCLE_SRC="$SCRIPTS_DIR/agent-lifecycle.sh"
GUARD_SRC="$SCRIPTS_DIR/agent-lifecycle-guard.py"
TEST_PARENT="${TMPDIR:-/tmp}"
TEST_PARENT="${TEST_PARENT%/}"
TEST_ROOT="$(mktemp -d "$TEST_PARENT/agent-lifecycle-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# The operator's own git configuration must not be able to change a result.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0
GIT_REAL="$(command -v git)"
export GIT_REAL

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

git_t() { git -c user.email=t@t -c user.name=t "$@"; }

# --- fixtures ----------------------------------------------------------------

# A bare "remote" plus a clone standing in for the primary checkout. The clone
# matters: `git clone` sets refs/remotes/origin/HEAD, which default_branch()
# reads.
new_fixture() {
  fixture="$TEST_ROOT/$1"
  remote="$fixture/remote.git"
  primary="$fixture/primary"
  guard="$primary/scripts/agent-lifecycle-guard.py"
  mkdir -p "$fixture"

  git init --quiet --bare --initial-branch=main "$remote"
  git clone --quiet "$remote" "$fixture/seed" 2>/dev/null
  mkdir -p "$fixture/seed/scripts"
  cp "$LIFECYCLE_SRC" "$fixture/seed/scripts/agent-lifecycle.sh"
  cp "$GUARD_SRC" "$fixture/seed/scripts/agent-lifecycle-guard.py"
  chmod +x "$fixture/seed/scripts/agent-lifecycle.sh" \
    "$fixture/seed/scripts/agent-lifecycle-guard.py"
  printf '%s\n' "seed" >"$fixture/seed/README.md"
  git_t -C "$fixture/seed" add -A
  git_t -C "$fixture/seed" commit --quiet -m "seed"
  git_t -C "$fixture/seed" push --quiet -u origin main

  git clone --quiet "$remote" "$primary"
}

throwaway_clone() {
  local clone
  clone="$(mktemp -d "$fixture/clone.XXXXXX")"
  git clone --quiet "$remote" "$clone"
  echo "$clone"
}

# Push a new commit to the bare remote from a throwaway clone, leaving the
# primary checkout's local main and origin/main stale. Echoes the new sha.
advance_remote() {
  local path="$1" clone
  clone="$(throwaway_clone)"
  mkdir -p "$(dirname "$clone/$path")"
  printf '%s\n' "advanced" >"$clone/$path"
  git_t -C "$clone" add -A
  git_t -C "$clone" commit --quiet -m "advance: $path"
  git_t -C "$clone" push --quiet origin main
  git -C "$clone" rev-parse HEAD
}

# Create a second branch on the bare remote, one commit ahead of main and
# carrying an authority-path file of its own. Echoes its tip sha.
create_remote_branch() {
  local name="$1" clone
  clone="$(throwaway_clone)"
  mkdir -p "$clone/.codex"
  printf '%s\n' "{}" >"$clone/.codex/hooks.json"
  printf '%s\n' "$name" >"$clone/$name.txt"
  git_t -C "$clone" add -A
  git_t -C "$clone" commit --quiet -m "open the $name branch"
  git_t -C "$clone" push --quiet origin "HEAD:refs/heads/$name"
  git -C "$clone" rev-parse HEAD
}

# Rewrite the remote's default branch so its previous tip is no longer an
# ancestor of it. Echoes the new sha.
rewrite_remote_default() {
  local clone
  clone="$(throwaway_clone)"
  printf '%s\n' "rewritten" >>"$clone/README.md"
  git_t -C "$clone" add -A
  git_t -C "$clone" commit --quiet --amend -m "rewritten history"
  git_t -C "$clone" push --quiet --force origin main
  git -C "$clone" rev-parse HEAD
}

break_remote() {
  git -C "$primary" remote set-url origin "$fixture/definitely-not-here.git"
}

# --- running and asserting ----------------------------------------------------

# Runs the lifecycle script from a given checkout, the way an operator would:
# `scripts/agent-lifecycle.sh` relative to the cwd. Sets $status.
run_lifecycle() {
  local dir="$1"
  shift
  status=0
  ( cd "$dir" && scripts/agent-lifecycle.sh "$@" ) \
    >"$fixture/out" 2>"$fixture/err" || status=$?
}

assert_status() { # label, expected
  [ "$status" = "$2" ] || fail "$1: exit status $status, expected $2
--- stdout ---
$(cat "$fixture/out")
--- stderr ---
$(cat "$fixture/err")"
}

assert_nonzero() { # label
  [ "$status" -ne 0 ] || fail "$1: exit status 0, expected nonzero
--- stdout ---
$(cat "$fixture/out")
--- stderr ---
$(cat "$fixture/err")"
}

assert_output_has() { # label, needle
  grep -qF -- "$2" "$fixture/out" "$fixture/err" || fail "$1: output does not contain '$2'; observed:
--- stdout ---
$(cat "$fixture/out")
--- stderr ---
$(cat "$fixture/err")"
}

assert_output_lacks() { # label, needle
  grep -qF -- "$2" "$fixture/out" "$fixture/err" && fail "$1: output unexpectedly contains '$2'; observed:
--- stdout ---
$(cat "$fixture/out")
--- stderr ---
$(cat "$fixture/err")"
  return 0
}

assert_equal() { # label, actual, expected
  [ "$2" = "$3" ] || fail "$1: got '$2', expected '$3'"
}

assert_missing() { # label, path
  [ ! -e "$2" ] || fail "$1: '$2' exists, expected it to be absent"
}

assert_present() { # label, path
  [ -e "$2" ] || fail "$1: '$2' is absent, expected it to exist"
}

assert_no_branch() { # label, branch
  git -C "$primary" rev-parse --verify --quiet "refs/heads/$2" >/dev/null && \
    fail "$1: branch '$2' exists, expected no branch to be created"
  return 0
}

base_record_of() { # worktree
  cat "$(git -C "$1" rev-parse --absolute-git-dir)/agent-base"
}

# The record is "<sha> <remote-branch>"; an --offline-base record carries the
# sha alone, so the expected branch field is then "".
assert_base_record() { # label, worktree, expected sha, expected branch field
  local record
  record="$(base_record_of "$2")"
  assert_equal "$1: agent-base sha field (record '$record')" \
    "$(printf '%s' "$record" | awk '{print $1}')" "$3"
  assert_equal "$1: agent-base branch field (record '$record')" \
    "$(printf '%s' "$record" | awk '{print $2}')" "$4"
}

worktree_from_output() { # label
  local path
  path="$(sed -n 's/^worktree: //p' "$fixture/out")"
  [ -n "$path" ] || fail "$1: no 'worktree:' line in output; observed:
$(cat "$fixture/out")"
  echo "$path"
}

commit_in_worktree() { # worktree, path, message
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "content" >"$1/$2"
  git_t -C "$1" add -A
  git_t -C "$1" commit --quiet -m "$3"
}

# start + one ordinary commit, pushed: the state close's proofs are meant to
# accept. Sets $wt.
started_and_published() { # branch
  run_lifecycle "$primary" start "$1"
  assert_status "start $1" 0
  wt="$(worktree_from_output "start $1")"
  commit_in_worktree "$wt" "notes/$1.md" "published work"
  git_t -C "$wt" push --quiet origin HEAD
}

# --- start --------------------------------------------------------------------

test_start_bases_on_fetched_remote_not_stale_local() {
  new_fixture start-stale
  local advanced stale_local wt head
  advanced="$(advance_remote advanced.txt)"
  stale_local="$(git -C "$primary" rev-parse refs/heads/main)"
  [ "$stale_local" != "$advanced" ] || \
    fail "fixture is not stale: local main and the remote tip are both $advanced"

  run_lifecycle "$primary" start topic
  assert_status "start with a stale local default branch" 0

  wt="$(worktree_from_output "start with a stale local default branch")"
  head="$(git -C "$wt" rev-parse HEAD)"
  assert_equal "worktree HEAD (must be the fetched remote tip, not local main $stale_local)" \
    "$head" "$advanced"
  assert_base_record "start with a stale local default branch" "$wt" "$advanced" "main"
}

test_start_fails_closed_when_fetch_fails() {
  new_fixture start-fetch-fails
  break_remote

  run_lifecycle "$primary" start topic
  assert_nonzero "start with an unreachable remote"
  assert_output_has "start with an unreachable remote" "fetch from 'origin' failed"
  assert_missing "start with an unreachable remote" "$fixture/primary-worktrees/topic"
  assert_no_branch "start with an unreachable remote" topic
}

test_start_offline_base_skips_the_fetch() {
  new_fixture start-offline-base
  local base wt
  base="$(git -C "$primary" rev-parse HEAD)"
  break_remote

  # Success against a remote that cannot be reached is itself the proof that no
  # fetch was attempted.
  run_lifecycle "$primary" start topic --offline-base "$base"
  assert_status "start --offline-base against an unreachable remote" 0
  assert_output_lacks "start --offline-base against an unreachable remote" "fetch from 'origin' failed"

  wt="$(worktree_from_output "start --offline-base")"
  assert_equal "worktree HEAD" "$(git -C "$wt" rev-parse HEAD)" "$base"
  # No fetch happened, so no remote branch is claimed: the sha stands alone.
  assert_base_record "start --offline-base" "$wt" "$base" ""
}

test_start_offline_base_records_a_named_base_ref() {
  new_fixture start-offline-base-ref
  local base wt
  base="$(git -C "$primary" rev-parse HEAD)"
  break_remote

  # An owner naming --base alongside --offline-base still means that branch as
  # the publication target; the record must carry it (unvalidated — no fetch
  # ran) so publish-check aims there instead of at the default branch.
  run_lifecycle "$primary" start topic --offline-base "$base" --base integration
  assert_status "start --offline-base --base integration" 0
  wt="$(worktree_from_output "start --offline-base --base integration")"
  assert_base_record "start --offline-base --base integration" "$wt" "$base" "integration"
}

test_start_refuses_an_existing_branch() {
  new_fixture start-existing-branch
  git -C "$primary" branch taken

  run_lifecycle "$primary" start taken
  assert_nonzero "start on an existing branch name"
  # The script's own refusal, not git's incidental one: a name collision must be
  # answered with the next action, and before anything is created.
  assert_output_has "start on an existing branch name" \
    "choose a new name or enter its existing worktree"
  assert_missing "start on an existing branch name" "$fixture/primary-worktrees/taken"
}

test_start_refuses_a_branch_already_on_the_remote() {
  new_fixture start-remote-branch
  create_remote_branch published >/dev/null

  # No local 'published' branch exists, so only the remote ref can refuse it;
  # missing this makes the eventual `git push origin HEAD` append the task to
  # someone else's published branch, or fail only after the work is done.
  run_lifecycle "$primary" start published
  assert_nonzero "start on a branch name already on the remote"
  assert_output_has "start on a branch name already on the remote" \
    "'origin/published' already exists"
  assert_missing "start on a branch name already on the remote" "$fixture/primary-worktrees/published"
}

test_start_base_ref_is_recorded_and_retargets_publish_check() {
  new_fixture start-base-ref
  local integration wt label
  integration="$(create_remote_branch integration)"

  run_lifecycle "$primary" start topic --base integration
  assert_status "start --base integration" 0
  wt="$(worktree_from_output "start --base integration")"
  assert_equal "worktree HEAD" "$(git -C "$wt" rev-parse HEAD)" "$integration"
  assert_base_record "start --base integration" "$wt" "$integration" "integration"

  commit_in_worktree "$wt" "notes/ordinary.md" "an ordinary change"
  label="publish-check in a --base integration worktree"
  run_lifecycle "$wt" publish-check
  # The integration branch carries a .codex/ file of its own. Measuring the
  # range from origin/main instead would drag that authority path into it and
  # exit 3, so a clean exit 0 is the proof that the recorded base ref is what
  # publish-check targets.
  assert_status "$label" 0
  assert_output_has "$label" "outgoing commits (origin/integration..HEAD):"
  assert_output_has "$label" "open a draft PR onto 'integration'"
  assert_output_lacks "$label" "origin/main..HEAD"
  assert_output_lacks "$label" "ATTENDED:"
}

# --- publish-check ------------------------------------------------------------

test_publish_check_rejects_a_dirty_tree() {
  new_fixture publish-dirty
  local wt
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  printf '%s\n' "work in progress" >"$wt/dirty-file.txt"

  run_lifecycle "$wt" publish-check
  assert_nonzero "publish-check on a dirty tree"
  assert_output_has "publish-check on a dirty tree" "working tree not clean"
  assert_output_has "publish-check on a dirty tree" "dirty-file.txt"
}

test_publish_check_stops_on_authority_paths() {
  new_fixture publish-authority
  local wt
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  commit_in_worktree "$wt" ".claude/settings.json" "touch the harness settings"

  run_lifecycle "$wt" publish-check
  assert_status "publish-check over a range touching .claude/" 3
  assert_output_has "publish-check over a range touching .claude/" "ATTENDED:"
  assert_output_has "publish-check over a range touching .claude/" ".claude/settings.json"
  assert_output_has "publish-check over a range touching .claude/" "Owner approval is required"
}

test_publish_check_authority_gate_matches_nested_agents_md() {
  new_fixture publish-nested-agents
  local wt
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  # Both harnesses read nested per-directory instruction files, so a scoped
  # AGENTS.md carries the same authority as the root one.
  commit_in_worktree "$wt" "skills/example/AGENTS.md" "scoped instructions"

  run_lifecycle "$wt" publish-check
  assert_status "publish-check over a nested AGENTS.md" 3
  assert_output_has "publish-check over a nested AGENTS.md" "ATTENDED:"
  assert_output_has "publish-check over a nested AGENTS.md" "skills/example/AGENTS.md"
}

test_publish_check_authority_gate_survives_a_rename() {
  new_fixture publish-authority-rename
  local wt label
  # The authority file has to exist in the base for a rename to be able to hide
  # it: the range then deletes .claude/settings.json and adds the new path, and
  # only a --no-renames diff still names the deleted side.
  advance_remote ".claude/settings.json" >/dev/null
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  mkdir -p "$wt/notes"
  git -C "$wt" mv .claude/settings.json notes/settings.json
  git_t -C "$wt" commit --quiet -m "move the settings out of .claude/"

  label="publish-check over a git mv of an authority path"
  run_lifecycle "$wt" publish-check
  assert_status "$label" 3
  assert_output_has "$label" "ATTENDED:"
  assert_output_has "$label" ".claude/settings.json"
}

test_publish_check_authority_gate_covers_claude_md() {
  new_fixture publish-authority-claude-md
  local wt label
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  commit_in_worktree "$wt" "CLAUDE.md" "edit the project instructions"

  label="publish-check over a range touching only CLAUDE.md"
  run_lifecycle "$wt" publish-check
  assert_status "$label" 3
  assert_output_has "$label" "ATTENDED:"
  assert_output_has "$label" "CLAUDE.md"
}

test_publish_check_passes_a_clean_range_and_reports_advance() {
  new_fixture publish-clean
  local wt label advanced
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  commit_in_worktree "$wt" "notes/ordinary.md" "an ordinary change"

  label="publish-check on a clean ordinary range"
  run_lifecycle "$wt" publish-check
  assert_status "$label" 0
  assert_output_has "$label" "publishable."
  assert_output_has "$label" "git push origin HEAD"
  assert_output_has "$label" "open a draft PR"
  assert_output_has "$label" "pause — merge is an owner decision"
  assert_output_has "$label" "an ordinary change"
  assert_output_lacks "$label" "ADVANCED:"

  # Same branch, but the remote default branch has since moved past the base.
  advanced="$(advance_remote later.txt)"
  label="publish-check after origin/main advanced past the base"
  run_lifecycle "$wt" publish-check
  assert_status "$label" 0
  assert_output_has "$label" "ADVANCED:"
  assert_output_has "$label" "$advanced"
  assert_output_has "$label" "publishable."
}

test_publish_check_stops_when_the_target_history_diverged() {
  new_fixture publish-diverged
  local wt base rewritten label
  advance_remote first.txt >/dev/null
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  base="$(git -C "$wt" rev-parse HEAD)"
  commit_in_worktree "$wt" "notes/ordinary.md" "an ordinary change"

  rewritten="$(rewrite_remote_default)"
  [ "$rewritten" != "$base" ] || fail "fixture did not rewrite the remote default branch"

  # The base was not merely overtaken, it was orphaned: that is an owner
  # decision, not an "ADVANCED" note the agent can reconcile on its own.
  label="publish-check after the target branch history was rewritten"
  run_lifecycle "$wt" publish-check
  assert_nonzero "$label"
  assert_output_has "$label" "DIVERGED:"
  assert_output_has "$label" "$base"
  assert_output_lacks "$label" "ADVANCED:"
  assert_output_lacks "$label" "publishable."
}

test_publish_check_warns_on_an_unrecorded_base() {
  new_fixture publish-unrecorded
  local wt label
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  commit_in_worktree "$wt" "notes/ordinary.md" "an ordinary change"
  rm "$(git -C "$wt" rev-parse --absolute-git-dir)/agent-base"

  # A missing record is a gap in provenance, not a publication failure: it must
  # be said out loud, and it must not be the sole reason for a nonzero exit.
  label="publish-check with no recorded base"
  run_lifecycle "$wt" publish-check
  assert_status "$label" 0
  assert_output_has "$label" "no recorded base"
  assert_output_has "$label" "publishable."
}

# --- close --------------------------------------------------------------------

test_close_refuses_a_dirty_worktree() {
  new_fixture close-dirty
  local wt
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  printf '%s\n' "unsaved" >"$wt/dirty-file.txt"

  run_lifecycle "$primary" close "$wt"
  assert_nonzero "close on a dirty worktree"
  assert_output_has "close on a dirty worktree" "uncommitted or untracked work"
  assert_present "close on a dirty worktree" "$wt"
}

test_close_refuses_an_unpushed_head() {
  new_fixture close-unpushed
  local wt
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  commit_in_worktree "$wt" "notes/unpushed.md" "committed but never pushed"

  run_lifecycle "$primary" close "$wt"
  assert_nonzero "close on an unpushed HEAD"
  assert_output_has "close on an unpushed HEAD" "not reachable from any origin branch"
  assert_present "close on an unpushed HEAD" "$wt"
}

test_close_refuses_ignored_files_until_asked() {
  new_fixture close-ignored
  local wt label
  started_and_published topic
  printf '%s\n' "scratch/" >"$wt/.gitignore"
  git_t -C "$wt" add -A
  git_t -C "$wt" commit --quiet -m "ignore scratch/"
  git_t -C "$wt" push --quiet origin HEAD
  mkdir -p "$wt/scratch"
  printf '%s\n' "local-only notes" >"$wt/scratch/notes.txt"

  # Ignored files pass `git status --porcelain` but die with the worktree.
  label="close on a worktree holding ignored files"
  run_lifecycle "$primary" close "$wt"
  assert_nonzero "$label"
  assert_output_has "$label" "contains ignored files"
  assert_output_has "$label" "--delete-ignored"
  assert_output_has "$label" "scratch/"
  assert_present "$label" "$wt"

  label="close --delete-ignored"
  run_lifecycle "$primary" close "$wt" --delete-ignored
  assert_status "$label" 0
  assert_output_has "$label" "removed: $wt"
  assert_missing "$label" "$wt"
}

test_close_normalizes_the_worktree_path() {
  new_fixture close-path-spelling
  local wt alt label
  started_and_published topic

  # An unnormalized spelling of the same directory: the macOS $TMPDIR /tmp form
  # of a /private/tmp worktree where the platform offers it, otherwise a
  # portable `..` round trip.
  alt="$wt/../$(basename "$wt")"
  if [ "${wt#/private/}" != "$wt" ] && [ -d "/${wt#/private/}" ]; then
    alt="/${wt#/private/}"
  fi
  [ "$alt" != "$wt" ] || fail "could not build an unnormalized spelling of '$wt'"

  label="close on an unnormalized path spelling ($alt)"
  run_lifecycle "$primary" close "$alt"
  assert_status "$label" 0
  assert_output_has "$label" "removed: $wt"
  assert_missing "$label" "$wt"
}

test_close_fails_closed_when_the_remote_is_unreachable() {
  new_fixture close-remote-down
  local wt label
  started_and_published topic
  break_remote

  # HEAD really is published, but that can no longer be proved; an unprovable
  # cleanup must refuse rather than trust the stale remote-tracking cache.
  label="close while the remote is unreachable"
  run_lifecycle "$primary" close "$wt"
  assert_nonzero "$label"
  assert_output_has "$label" "fetch from 'origin' failed"
  assert_output_has "$label" "refusing cleanup"
  assert_present "$label" "$wt"
}

test_close_removes_a_pushed_worktree_and_keeps_the_branch() {
  new_fixture close-pushed
  local wt shim saved_path removal
  started_and_published topic

  # A trace shim ahead of git on PATH records what the script actually ran, so
  # "removed without --force" is proved by the invocation, not by its wording.
  shim="$fixture/shim"
  mkdir -p "$shim"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >>"$GIT_TRACE_LOG"' \
    'exec "$GIT_REAL" "$@"' >"$shim/git"
  chmod +x "$shim/git"
  export GIT_TRACE_LOG="$fixture/git-calls.log"
  : >"$GIT_TRACE_LOG"
  saved_path="$PATH"
  PATH="$shim:$PATH"
  run_lifecycle "$primary" close "$wt"
  PATH="$saved_path"

  assert_status "close on a pushed, clean worktree" 0
  removal="$(grep -E '^worktree remove ' "$GIT_TRACE_LOG" || true)"
  [ -n "$removal" ] || fail "close on a pushed, clean worktree: no 'git worktree remove' was traced; git calls observed:
$(cat "$GIT_TRACE_LOG")"
  case " $removal " in
    *" --force "*|*" -f "*)
      fail "close on a pushed, clean worktree: removal used force: 'git $removal', expected an unforced removal" ;;
  esac
  unset GIT_TRACE_LOG
  assert_output_has "close on a pushed, clean worktree" "--force is never used"
  assert_output_has "close on a pushed, clean worktree" "branch 'topic' kept"
  assert_missing "close on a pushed, clean worktree" "$wt"
  git -C "$primary" rev-parse --verify --quiet refs/heads/topic >/dev/null || \
    fail "close on a pushed, clean worktree: branch 'topic' was deleted, expected it to be kept"
}

test_close_refuses_after_the_remote_branch_was_deleted() {
  new_fixture close-remote-deleted
  local wt
  started_and_published topic

  # The push landed once, but the remote no longer holds the branch; the stale
  # remote-tracking ref must not vouch for HEAD, so close has to prune and
  # refuse rather than delete the only remaining copy of the work.
  git -C "$remote" update-ref -d refs/heads/topic

  run_lifecycle "$primary" close "$wt"
  assert_nonzero "close after the remote deleted the branch"
  assert_output_has "close after the remote deleted the branch" \
    "not reachable from any origin branch"
  [ -d "$wt" ] || fail "close after the remote deleted the branch: worktree was removed"
}

test_close_ignores_other_remotes_tracking_refs() {
  new_fixture close-other-remote
  local wt
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  commit_in_worktree "$wt" "notes/topic.md" "unpublished work"
  # A second remote holds HEAD, but the close proof fetched and pruned only
  # origin — backup's tracking ref must not vouch for the work.
  git init --quiet --bare "$fixture/backup.git"
  git -C "$wt" remote add backup "$fixture/backup.git"
  git_t -C "$wt" push --quiet backup HEAD

  run_lifecycle "$primary" close "$wt"
  assert_nonzero "close with HEAD only on a foreign remote"
  assert_output_has "close with HEAD only on a foreign remote" "not reachable from any origin branch"
  [ -d "$wt" ] || fail "close with HEAD only on a foreign remote: worktree was removed"
}

test_close_of_a_detached_worktree_reports_success() {
  new_fixture close-detached
  local wt
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  git -C "$wt" checkout --quiet --detach HEAD

  # There is no branch to report; the removal still succeeded, so the exit
  # status must say so.
  run_lifecycle "$primary" close "$wt"
  assert_status "close on a detached-HEAD worktree" 0
  assert_output_has "close on a detached-HEAD worktree" "removed: $wt"
  assert_missing "close on a detached-HEAD worktree" "$wt"
}

test_start_refuses_a_dir_inside_the_primary_checkout() {
  new_fixture start-nested-dir
  # A worktree nested in the primary would leave the primary holding
  # untracked mutable state — no longer inspect-only.
  run_lifecycle "$primary" start topic --dir "$primary/nested"
  assert_nonzero "start --dir inside the primary checkout"
  assert_output_has "start --dir inside the primary checkout" "inside the primary checkout"
  assert_no_branch "start --dir inside the primary checkout" topic
  [ ! -e "$primary/nested" ] || fail "start --dir inside the primary checkout: nested dir was created"

  # The relative spelling resolves against the cwd (the primary) and must
  # be caught just the same.
  run_lifecycle "$primary" start topic --dir nested
  assert_nonzero "start --dir with a relative path inside the primary"
  assert_no_branch "start --dir with a relative path inside the primary" topic

  # A nonexistent component followed by `..` re-enters real directories;
  # the containment check must survive the lexical detour.
  run_lifecycle "$primary" start topic --dir "$fixture/ghost/../primary/nested"
  assert_nonzero "start --dir dodging containment via dot segments"
  assert_no_branch "start --dir dodging containment via dot segments" topic
  [ ! -e "$primary/nested" ] || fail "start --dir dodging containment via dot segments: nested dir was created"
}

test_close_proof_survives_hidden_untracked_config() {
  new_fixture close-hidden-untracked
  local wt
  started_and_published topic
  printf 'precious\n' >"$wt/scratch.txt"
  # status.showUntrackedFiles=no hides untracked files from a bare
  # `status --porcelain`; the proof must force them visible or the removal
  # destroys the only copy.
  git -C "$wt" config status.showUntrackedFiles no

  run_lifecycle "$primary" close "$wt"
  assert_nonzero "close with untracked files hidden by config"
  assert_output_has "close with untracked files hidden by config" "uncommitted or untracked"
  [ -f "$wt/scratch.txt" ] || fail "close with untracked files hidden by config: scratch.txt was destroyed"
}

test_start_fails_when_the_default_branch_cannot_be_refreshed() {
  new_fixture sethead
  # Point the remote's HEAD at a branch that does not exist: the fetch still
  # succeeds, but the remote can no longer answer "what is the default
  # branch?" — exactly the case where continuing on the cached name could
  # base the task on a former default.
  git -C "$remote" symbolic-ref HEAD refs/heads/ghost

  run_lifecycle "$primary" start topic
  assert_nonzero "start with an unanswerable remote HEAD"
  assert_output_has "start with an unanswerable remote HEAD" "could not refresh"
  assert_no_branch "start with an unanswerable remote HEAD" topic

  # With --base the cached default-branch name is never consulted, so the
  # same broken remote HEAD must not stop an explicitly-based start.
  run_lifecycle "$primary" start topic --base main
  assert_status "start --base with an unanswerable remote HEAD" 0
}

# --- guard --------------------------------------------------------------------

json_file_tool() { # tool, file_path, cwd
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$1" "$2" "$3"
}

json_bash() { # command, cwd
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$2"
}

json_apply_patch() { # patch body (with \n escapes), cwd
  printf '{"tool_name":"apply_patch","tool_input":{"patch":"%s"},"cwd":"%s"}' "$1" "$2"
}

guard_case() { # label, expected status, stdin payload
  local status=0
  printf '%s' "$3" >"$fixture/guard.in"
  "$guard" <"$fixture/guard.in" >"$fixture/guard.out" 2>"$fixture/guard.err" || status=$?
  [ "$status" = "$2" ] || fail "guard, $1: exit status $status, expected $2
--- payload ---
$3
--- stderr ---
$(cat "$fixture/guard.err")"
}

# One fixture serves every guard group: a primary checkout holding the guard
# (find_primary_root derives the answer from the script's own location) plus a
# worktree to stand outside it.
GUARD_FIXTURE_READY=0
guard_fixture() {
  if [ "$GUARD_FIXTURE_READY" = "1" ]; then
    fixture="$TEST_ROOT/guard"
    remote="$fixture/remote.git"
    primary="$fixture/primary"
    guard="$primary/scripts/agent-lifecycle-guard.py"
    return 0
  fi
  new_fixture guard
  run_lifecycle "$primary" start topic
  assert_status "start (guard fixture)" 0
  guard_wt="$(worktree_from_output "start (guard fixture)")"
  GUARD_FIXTURE_READY=1
}

test_guard_blocks_primary_checkout_mutation() {
  guard_fixture
  guard_case "Edit inside the primary checkout" 2 \
    "$(json_file_tool Edit "$primary/README.md" "$primary")"
  guard_case "Edit inside a worktree" 0 \
    "$(json_file_tool Edit "$guard_wt/README.md" "$guard_wt")"
  guard_case "git commit with cwd in the primary checkout" 2 \
    "$(json_bash "git commit -m wip" "$primary")"
  guard_case "git commit with cwd in a worktree" 0 \
    "$(json_bash "git commit -m wip" "$guard_wt")"
  guard_case "git add with cwd in the primary checkout" 2 \
    "$(json_bash "git add -A" "$primary")"
  guard_case "git add with cwd in a worktree" 0 \
    "$(json_bash "git add -A" "$guard_wt")"
  guard_case "git -c <config> commit in the primary checkout" 2 \
    "$(json_bash "git -c user.email=a@b commit -m wip" "$primary")"
  guard_case "git checkout in the primary checkout" 2 \
    "$(json_bash "git checkout -b scratch" "$primary")"
  guard_case "git commit with quoted arguments in the primary checkout" 2 \
    "$(json_bash "git commit -m 'a b'" "$primary")"
  guard_case "git gc in the primary checkout" 2 \
    "$(json_bash "git gc --prune=now" "$primary")"
}

test_guard_allows_inspection_and_ignores_lookalikes() {
  guard_fixture
  guard_case "git status in the primary checkout" 0 \
    "$(json_bash "git status --porcelain" "$primary")"
  guard_case "git branch -a in the primary checkout" 0 \
    "$(json_bash "git branch -a" "$primary")"
  guard_case "git config --get in the primary checkout" 0 \
    "$(json_bash "git config --get user.name" "$primary")"
  guard_case "git reflog in the primary checkout" 0 \
    "$(json_bash "git reflog" "$primary")"
  guard_case "git tag --list with a pattern in the primary checkout" 0 \
    "$(json_bash "git tag -l v*" "$primary")"
  guard_case "git log piped to head in the primary checkout" 0 \
    "$(json_bash "git log --oneline | head -5" "$primary")"
  guard_case "a harmless env prefix on an inspection command" 0 \
    "$(json_bash "GIT_PAGER=cat git log -1" "$primary")"
  guard_case "a double-quoted string that merely mentions git commit" 0 \
    "$(json_bash "echo \\\"a && git commit\\\"" "$primary")"
  guard_case "a single-quoted string that mentions a piped git commit" 0 \
    "$(json_bash "echo 'harmless | git commit -m wip'" "$primary")"
  guard_case "unbalanced quotes fail open" 0 \
    "$(json_bash "echo 'oops" "$primary")"
  guard_case "unparseable stdin" 0 "not json at all"
}

test_guard_deliberate_fail_opens() {
  guard_fixture
  # ADR 0004's shell interpretation was retired by ADR 0005 after its first
  # production use produced both a wrong block and a bypass. Each case below
  # was once denied (or analyzed) by that machinery; these pins record the
  # retirement as a decision, not an accident. The payloads only pass
  # through the guard; nothing runs. What still holds the line: worktree
  # isolation, close's loss proofs, GitHub's ruleset, and PR review.
  guard_case "a plain shell write into the primary (accepted fail-open)" 0 \
    "$(json_bash "rm f.txt" "$primary")"
  guard_case "a redirection into the primary (accepted fail-open)" 0 \
    "$(json_bash "echo x > $primary/f" "$TEST_ROOT")"
  guard_case "local branch creation in the primary (accepted fail-open)" 0 \
    "$(json_bash "git branch scratch" "$primary")"
  guard_case "a fetch writing a local branch (accepted fail-open)" 0 \
    "$(json_bash "git fetch origin main:scratch" "$guard_wt")"
  # Retired: -C/--git-dir/environment/cd/runner tracking. A command that
  # names its own repository fails open — resolving where it operates is
  # the interpretation ADR 0005 removed.
  guard_case "git -C <primary> commit from outside (retired: -C tracking)" 0 \
    "$(json_bash "git -C $primary commit -m wip" "$TEST_ROOT")"
  guard_case "cd <primary> && git commit from outside (retired: cd tracking)" 0 \
    "$(json_bash "cd $primary && git commit -m wip" "$TEST_ROOT")"
  guard_case "GIT_DIR prefix at the primary (retired: env tracking)" 0 \
    "$(json_bash "GIT_DIR=$primary/.git GIT_WORK_TREE=$primary git reset --hard HEAD" "$TEST_ROOT")"
  guard_case "command git commit in the primary (retired: runner peeling)" 0 \
    "$(json_bash "command git commit -m wip" "$primary")"
  # Retired: all push analysis. GitHub's ruleset is the push authority; the
  # 2>&1 case is the production wrong block that triggered ADR 0005.
  guard_case "a plain push with a redirection (the production wrong block)" 0 \
    "$(json_bash "git push origin HEAD 2>&1" "$guard_wt")"
  guard_case "git push --force (retired: push analysis)" 0 \
    "$(json_bash "git push --force origin topic" "$guard_wt")"
  guard_case "git push naming the default branch (retired: push analysis)" 0 \
    "$(json_bash "git push origin main" "$guard_wt")"
  guard_case "git push --tags (retired: push analysis)" 0 \
    "$(json_bash "git push origin --tags" "$guard_wt")"
  # Retired: shared-state and recovery-surgery rules.
  guard_case "git config write in the primary (retired: shared-state rules)" 0 \
    "$(json_bash "git config user.name x" "$primary")"
  guard_case "git remote set-url from a worktree (retired: shared-state rules)" 0 \
    "$(json_bash "git remote set-url origin /elsewhere" "$guard_wt")"
  guard_case "git reflog expire in the primary (retired: recovery-surgery rules)" 0 \
    "$(json_bash "git reflog expire --expire=now --all" "$primary")"
  # Retired: worktree rules. close stays the recommended remover — as a
  # helper: Git itself refuses to remove a dirty worktree unforced, and
  # forced removal is prohibited in guidance, not by this gate.
  guard_case "git worktree remove from the primary cwd (retired: worktree rules)" 0 \
    "$(json_bash "git worktree remove $guard_wt" "$primary")"
  guard_case "git worktree remove --force from the primary cwd (guidance-only prohibition)" 0 \
    "$(json_bash "git worktree remove --force $guard_wt" "$primary")"
  guard_case "git worktree add without an explicit base (retired: worktree rules)" 0 \
    "$(json_bash "git worktree add ../x" "$TEST_ROOT")"
}

test_guard_apply_patch() {
  guard_fixture
  guard_case "apply_patch naming a file in the primary checkout" 2 \
    "$(json_apply_patch "*** Begin Patch\\n*** Update File: $primary/CLAUDE.md\\n@@\\n-a\\n+b\\n*** End Patch" "$TEST_ROOT")"
  guard_case "apply_patch naming a relative file from a worktree cwd" 0 \
    "$(json_apply_patch "*** Begin Patch\\n*** Update File: foo.md\\n@@\\n-a\\n+b\\n*** End Patch" "$guard_wt")"
  guard_case "an unparseable apply_patch with a primary-checkout cwd" 2 \
    "$(json_apply_patch "no headers here" "$primary")"
}

test_guard_escape_hatch_lifts_the_gate() {
  guard_fixture
  export AGENT_LIFECYCLE_ALLOW_PRIMARY=1
  guard_case "escape hatch, Edit in the primary checkout" 0 \
    "$(json_file_tool Edit "$primary/README.md" "$primary")"
  guard_case "escape hatch, git commit in the primary checkout" 0 \
    "$(json_bash "git commit -m wip" "$primary")"
  unset AGENT_LIFECYCLE_ALLOW_PRIMARY
}

test_start_bases_on_fetched_remote_not_stale_local
test_start_fails_closed_when_fetch_fails
test_start_offline_base_skips_the_fetch
test_start_offline_base_records_a_named_base_ref
test_start_refuses_an_existing_branch
test_start_refuses_a_branch_already_on_the_remote
test_start_fails_when_the_default_branch_cannot_be_refreshed
test_start_refuses_a_dir_inside_the_primary_checkout
test_start_base_ref_is_recorded_and_retargets_publish_check
test_publish_check_rejects_a_dirty_tree
test_publish_check_stops_on_authority_paths
test_publish_check_authority_gate_matches_nested_agents_md
test_publish_check_authority_gate_survives_a_rename
test_publish_check_authority_gate_covers_claude_md
test_publish_check_passes_a_clean_range_and_reports_advance
test_publish_check_stops_when_the_target_history_diverged
test_publish_check_warns_on_an_unrecorded_base
test_close_refuses_a_dirty_worktree
test_close_refuses_an_unpushed_head
test_close_refuses_ignored_files_until_asked
test_close_proof_survives_hidden_untracked_config
test_close_normalizes_the_worktree_path
test_close_fails_closed_when_the_remote_is_unreachable
test_close_removes_a_pushed_worktree_and_keeps_the_branch
test_close_refuses_after_the_remote_branch_was_deleted
test_close_ignores_other_remotes_tracking_refs
test_close_of_a_detached_worktree_reports_success
test_guard_blocks_primary_checkout_mutation
test_guard_allows_inspection_and_ignores_lookalikes
test_guard_deliberate_fail_opens
test_guard_apply_patch
test_guard_escape_hatch_lifts_the_gate

echo "agent-lifecycle tests passed"
