#!/usr/bin/env python3
"""PreToolUse guard for the agent repository lifecycle (ADR 0004, reduced
to a thin primary-checkout gate by ADR 0005).

One policy, two registrations: .claude/settings.json (Claude Code) and
.codex/hooks.json (Codex) both run this script before file-edit and shell
tools. Both harnesses honour the same contract: exit 0 allows the call,
exit 2 blocks it with the stderr text as the reason.

The guard is a location gate, not a command interpreter and not a
security boundary. It denies exactly two things:

  1. file edits (and apply_patch targets) inside the primary checkout;
  2. a direct `git <mutating-verb>` invocation whose session cwd is
     inside the primary checkout — a set-membership check on the verb,
     nothing more.

Everything else deliberately fails open — a miss must be an allow, never
a wrong block. ADR 0004's shell interpretation (command segmentation,
`cd`/environment/`-C` tracking, runner peeling, push/refspec/redirection
analysis, shared-state and worktree-removal rules) was retired by ADR
0005 after its first production use yielded both a wrong block and a
bypass. Deliberately uncovered, and pinned as fail-opens in
test_guard_deliberate_fail_opens: compound commands whose first word is
not `git`, invocations that name their own repository (`-C`,
`--git-dir`, `--work-tree`, a `GIT_DIR` environment prefix), runner
prefixes, plain shell writes, every push spelling, config/remote writes,
and `git worktree` operations. The boundaries that carry the real weight
are worktree isolation, `close`'s loss proofs (a helper, not an enforced
path), GitHub's ruleset, and owner review at the PR.

The owner escape hatch AGENT_LIFECYCLE_ALLOW_PRIMARY=1 lifts the gate.
"""

import json
import os
import re
import shlex
import sys

FILE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}

# Deny these verbs when the session cwd is the primary checkout.
MUTATING_GIT = {
    "add", "commit", "merge", "rebase", "cherry-pick", "revert", "am",
    "apply", "reset", "restore", "switch", "checkout", "stash", "clean",
    "mv", "rm", "pull", "gc", "repack", "update-ref", "replace",
    "filter-branch", "prune",
}

# Global git flags that take a separate value; without consuming them the
# value would be misread as the subcommand.
GIT_VALUE_FLAGS = {"-c", "--config-env", "--namespace", "--exec-path"}

START_HINT = "scripts/agent-lifecycle.sh start <branch>  (fetches, then creates an isolated worktree)"

PATCH_HEADER = re.compile(
    r"^\*\*\* (?:Update|Add|Delete) File: (.+)$|^\*\*\* Move to: (.+)$",
    re.MULTILINE,
)


def allow():
    sys.exit(0)


def deny_primary(fact):
    if os.environ.get("AGENT_LIFECYCLE_ALLOW_PRIMARY") == "1":
        return
    sys.stderr.write(
        "BLOCKED by the agent lifecycle guard.\n"
        f"Detected: {fact}\n"
        "Rule: agents may inspect the primary checkout but never mutate it\n"
        f"Safe next action: {START_HINT}\n"
    )
    sys.exit(2)


def find_primary_root():
    """The primary checkout is the one whose .git is a directory.

    Derived from this script's own real location (symlink-resolved) so the
    answer is right even when the session, or the registered hook path,
    lives in a worktree or behind a symlink.
    """
    script_root = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    dot_git = os.path.join(script_root, ".git")
    if os.path.isdir(dot_git):
        return os.path.realpath(script_root)
    if os.path.isfile(dot_git):
        try:
            with open(dot_git, encoding="utf-8") as f:
                content = f.read().strip()
        except OSError:
            return None
        if content.startswith("gitdir:"):
            gitdir = content[len("gitdir:"):].strip()
            # <primary>/.git/worktrees/<id> -> <primary>
            marker = f"{os.sep}.git{os.sep}worktrees{os.sep}"
            idx = gitdir.find(marker)
            if idx != -1:
                return os.path.realpath(gitdir[:idx])
    return None


def inside(path, root):
    path = os.path.realpath(path)
    return path == root or path.startswith(root + os.sep)


def git_verb(tokens):
    """The subcommand of a direct git invocation, or None to fail open.

    None whenever the command's first word is not `git` (compound
    commands, runners, environment prefixes) or the invocation names its
    own repository (`-C`, `--git-dir`, `--work-tree`) — resolving where
    such a command operates is the shell interpretation ADR 0005 retired.
    """
    if not tokens or os.path.basename(tokens[0]) != "git":
        return None
    i = 1
    while i < len(tokens):
        t = tokens[i]
        if t.startswith("-C") or t.startswith("--git-dir") \
                or t.startswith("--work-tree"):
            return None
        if t in GIT_VALUE_FLAGS:
            i += 2
            continue
        if t.startswith("-"):
            i += 1
            continue
        return t
    return None


def check_bash(command, cwd, primary):
    if not cwd or not inside(cwd, primary):
        return
    try:
        tokens = shlex.split(command)
    except ValueError:
        return  # unbalanced quotes: documented fail-open
    verb = git_verb(tokens)
    if verb in MUTATING_GIT:
        deny_primary(
            f"`git {verb}` with the session directory inside the primary checkout at {primary}")


def apply_patch_targets(tool_input):
    text_parts = [v for v in tool_input.values() if isinstance(v, str)]
    targets = []
    for text in text_parts:
        for m in PATCH_HEADER.finditer(text):
            targets.append(m.group(1) or m.group(2))
    return targets


def main():
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)  # unparseable input is a harness change, not a violation

    primary = find_primary_root()
    if primary is None:
        sys.exit(0)

    tool = payload.get("tool_name", "")
    tool_input = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or ""

    if tool in FILE_TOOLS:
        target = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
        if target and not os.path.isabs(target):
            target = os.path.join(cwd, target) if cwd else ""
        if target and inside(target, primary):
            deny_primary(f"{tool} writing {target}, inside the primary checkout at {primary}")
    elif tool == "apply_patch":
        targets = apply_patch_targets(tool_input)
        for raw in targets:
            resolved = raw if os.path.isabs(raw) else (os.path.join(cwd, raw) if cwd else "")
            if resolved and inside(resolved, primary):
                deny_primary(f"apply_patch targeting {resolved}, inside the primary checkout at {primary}")
        # Only when no per-file headers could be parsed does the session cwd
        # decide — otherwise a primary-cwd patch to a worktree file would be
        # falsely blocked.
        if not targets and cwd and inside(cwd, primary):
            deny_primary(f"an unparseable apply_patch with the session cwd inside the primary checkout at {primary}")
    elif tool == "Bash":
        command = tool_input.get("command") or ""
        if command:
            check_bash(command, cwd, primary)

    allow()


if __name__ == "__main__":
    main()
