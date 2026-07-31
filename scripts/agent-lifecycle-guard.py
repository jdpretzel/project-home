#!/usr/bin/env python3
"""PreToolUse guard for the agent repository lifecycle (ADR 0004).

One policy, two registrations: .claude/settings.json (Claude Code) and
.codex/hooks.json (Codex) both run this script before file-edit and shell
tools. Both harnesses honour the same contract: exit 0 allows the call,
exit 2 blocks it with the stderr text as the reason.

It blocks only high-confidence violations, and every denial names the
detected fact, the violated rule, and the exact safe next action:

  1. file edits inside the primary checkout (agents work in worktrees);
  2. mutating git commands run inside the primary checkout;
  3. force pushes, anywhere (published history is never rewritten);
  4. `git worktree remove --force`, anywhere (it can destroy unpushed work).

This is mistake prevention for agents, not an adversarial security
boundary: the script is repo-owned and model-writable, and raw shell
writes (redirection, sed -i) in the primary checkout are deliberately not
parsed for. The owner escape hatch is AGENT_LIFECYCLE_ALLOW_PRIMARY=1.
"""

import json
import os
import re
import sys

FILE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
MUTATING_GIT = {
    "commit", "merge", "rebase", "cherry-pick", "revert", "am", "apply",
    "reset", "restore", "switch", "checkout", "stash", "clean", "mv", "rm",
    "pull",
}
START_HINT = "scripts/agent-lifecycle.sh start <branch>  (fetches, then creates an isolated worktree)"


def allow():
    sys.exit(0)


def deny(fact, rule, action):
    sys.stderr.write(
        "BLOCKED by the agent lifecycle guard.\n"
        f"Detected: {fact}\n"
        f"Rule: {rule}\n"
        f"Safe next action: {action}\n"
    )
    sys.exit(2)


def find_primary_root():
    """The primary checkout is the one whose .git is a directory.

    Derived from this script's own location so the answer is right even
    when the session (and this copy of the script) lives in a worktree.
    """
    script_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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


def shell_segments(command):
    """Split a shell command on unquoted-ish separators; conservative on
    purpose — a miss means an allow, never a wrong block."""
    return [s.strip() for s in re.split(r"(?:&&|\|\||[;|\n])", command) if s.strip()]


def git_subcommand(segment):
    """Return git's subcommand and any -C target for a segment that invokes
    git directly; (None, None) otherwise."""
    try:
        words = segment.split()
    except AttributeError:
        return None, None
    if not words or os.path.basename(words[0]) != "git":
        return None, None
    c_target = None
    i = 1
    while i < len(words):
        w = words[i]
        if w == "-C" and i + 1 < len(words):
            c_target = words[i + 1].strip("'\"")
            i += 2
            continue
        if w.startswith("-"):
            i += 1
            continue
        return w, c_target
    return None, c_target


def check_bash(command, cwd, primary):
    for seg in shell_segments(command):
        sub, c_target = git_subcommand(seg)
        if sub is None:
            continue

        if sub == "push" and re.search(r"(^|\s)(--force(-with-lease|-if-includes)?(=\S*)?|-f)(\s|$)", seg):
            deny(
                f"a force push: `{seg}`",
                "published or shared history is never rewritten; plain pushes only",
                "push without force; if the branch truly needs rewriting, ask the owner first",
            )

        if sub == "worktree" and re.search(r"\bremove\b", seg) and re.search(r"(^|\s)(--force|-f)(\s|$)", seg):
            deny(
                f"`git worktree remove --force`: `{seg}`",
                "forced worktree removal can destroy uncommitted or unpushed work",
                "run `scripts/agent-lifecycle.sh close <path>` — it proves nothing is lost, then removes without force",
            )

        if sub in MUTATING_GIT:
            effective = c_target if c_target else cwd
            if effective and not os.path.isabs(effective):
                effective = os.path.join(cwd or "/", effective)
            if effective and inside(effective, primary):
                deny(
                    f"`git {sub}` running against the primary checkout at {primary}",
                    "agents may inspect the primary checkout but never mutate it",
                    START_HINT,
                )


def main():
    if os.environ.get("AGENT_LIFECYCLE_ALLOW_PRIMARY") == "1":
        allow()

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
            target = os.path.join(cwd or "/", target)
        if target and inside(target, primary):
            deny(
                f"{tool} writing {target}, inside the primary checkout at {primary}",
                "agents may inspect the primary checkout but never mutate it",
                START_HINT,
            )
    elif tool == "apply_patch":
        if cwd and inside(cwd, primary):
            deny(
                f"an apply_patch with the session cwd inside the primary checkout at {primary}",
                "agents may inspect the primary checkout but never mutate it",
                START_HINT,
            )
    elif tool == "Bash":
        command = tool_input.get("command") or ""
        if command:
            check_bash(command, cwd, primary)

    allow()


if __name__ == "__main__":
    main()
