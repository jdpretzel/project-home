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

# Push a new commit to the bare remote from a throwaway third clone, leaving the
# primary checkout's local main and origin/main stale. Echoes the new sha.
advance_remote() {
  local name="$1" clone
  clone="$(mktemp -d "$fixture/advancer.XXXXXX")"
  git clone --quiet "$remote" "$clone"
  printf '%s\n' "advanced" >"$clone/$name"
  git_t -C "$clone" add -A
  git_t -C "$clone" commit --quiet -m "advance: $name"
  git_t -C "$clone" push --quiet origin main
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

recorded_base_of() { # worktree path
  cat "$(git -C "$1" rev-parse --absolute-git-dir)/agent-base"
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
  assert_equal "recorded base file" "$(recorded_base_of "$wt")" "$advanced"
}

test_start_fails_closed_when_fetch_fails() {
  new_fixture start-fetch-fails
  break_remote

  run_lifecycle "$primary" start topic
  [ "$status" -ne 0 ] || assert_status "start with an unreachable remote" "nonzero"
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
  assert_equal "recorded base file" "$(recorded_base_of "$wt")" "$base"
}

test_start_refuses_an_existing_branch() {
  new_fixture start-existing-branch
  git -C "$primary" branch taken

  run_lifecycle "$primary" start taken
  [ "$status" -ne 0 ] || assert_status "start on an existing branch name" "nonzero"
  # The script's own refusal, not git's incidental one: a name collision must be
  # answered with the next action, and before anything is created.
  assert_output_has "start on an existing branch name" \
    "choose a new name or enter its existing worktree"
  assert_missing "start on an existing branch name" "$fixture/primary-worktrees/taken"
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
  [ "$status" -ne 0 ] || assert_status "publish-check on a dirty tree" "nonzero"
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

test_publish_check_passes_a_clean_range_and_reports_advance() {
  new_fixture publish-clean
  local wt label
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
  local advanced
  advanced="$(advance_remote later.txt)"
  label="publish-check after origin/main advanced past the base"
  run_lifecycle "$wt" publish-check
  assert_status "$label" 0
  assert_output_has "$label" "ADVANCED:"
  assert_output_has "$label" "$advanced"
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
  [ "$status" -ne 0 ] || assert_status "close on a dirty worktree" "nonzero"
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
  [ "$status" -ne 0 ] || assert_status "close on an unpushed HEAD" "nonzero"
  assert_output_has "close on an unpushed HEAD" "not reachable from any remote branch"
  assert_present "close on an unpushed HEAD" "$wt"
}

test_close_removes_a_pushed_worktree_and_keeps_the_branch() {
  new_fixture close-pushed
  local wt shim saved_path removal
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"
  commit_in_worktree "$wt" "notes/pushed.md" "published work"
  git_t -C "$wt" push --quiet origin HEAD

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

# --- guard --------------------------------------------------------------------

json_file_tool() { # tool, file_path, cwd
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$1" "$2" "$3"
}

json_bash() { # command, cwd
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$2"
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

test_guard_matrix() {
  new_fixture guard
  local wt
  run_lifecycle "$primary" start topic
  assert_status "start" 0
  wt="$(worktree_from_output "start")"

  guard_case "Edit inside the primary checkout" 2 \
    "$(json_file_tool Edit "$primary/README.md" "$primary")"
  guard_case "Edit inside a worktree" 0 \
    "$(json_file_tool Edit "$wt/README.md" "$wt")"
  guard_case "git commit with cwd in the primary checkout" 2 \
    "$(json_bash "git commit -m wip" "$primary")"
  guard_case "git commit with cwd in a worktree" 0 \
    "$(json_bash "git commit -m wip" "$wt")"
  guard_case "git -C <primary> commit from outside either checkout" 2 \
    "$(json_bash "git -C $primary commit -m wip" "$TEST_ROOT")"
  guard_case "git status in the primary checkout" 0 \
    "$(json_bash "git status --porcelain" "$primary")"
  guard_case "git push --force from a worktree" 2 \
    "$(json_bash "git push --force origin topic" "$wt")"
  guard_case "plain git push from a worktree" 0 \
    "$(json_bash "git push origin HEAD" "$wt")"
  guard_case "git worktree remove --force" 2 \
    "$(json_bash "git worktree remove --force $wt" "$TEST_ROOT")"
  guard_case "a shell command that merely mentions git commit" 0 \
    "$(json_bash "echo 'git commit'" "$primary")"
  guard_case "unparseable stdin" 0 "not json at all"

  export AGENT_LIFECYCLE_ALLOW_PRIMARY=1
  guard_case "an otherwise-blocked Edit under the owner escape hatch" 0 \
    "$(json_file_tool Edit "$primary/README.md" "$primary")"
  unset AGENT_LIFECYCLE_ALLOW_PRIMARY
}

test_start_bases_on_fetched_remote_not_stale_local
test_start_fails_closed_when_fetch_fails
test_start_offline_base_skips_the_fetch
test_start_refuses_an_existing_branch
test_publish_check_rejects_a_dirty_tree
test_publish_check_stops_on_authority_paths
test_publish_check_passes_a_clean_range_and_reports_advance
test_close_refuses_a_dirty_worktree
test_close_refuses_an_unpushed_head
test_close_removes_a_pushed_worktree_and_keeps_the_branch
test_close_of_a_detached_worktree_reports_success
test_guard_matrix

echo "agent-lifecycle tests passed"
