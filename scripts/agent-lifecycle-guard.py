#!/usr/bin/env python3
"""PreToolUse guard for the agent repository lifecycle (ADR 0004).

One policy, two registrations: .claude/settings.json (Claude Code) and
.codex/hooks.json (Codex) both run this script before file-edit and shell
tools. Both harnesses honour the same contract: exit 0 allows the call,
exit 2 blocks it with the stderr text as the reason.

It blocks only high-confidence violations, and every denial names the
detected fact, the violated rule, and the exact safe next action:

  1. file edits (and apply_patch targets) inside the primary checkout;
  2. mutating git commands run against the primary checkout, including
     via -C, --git-dir/--work-tree, or a `cd` earlier in the command;
  3. force pushes — flags or `+`/`:`-refspecs — and remote deletions,
     anywhere (published history is never rewritten unattended);
  4. `git worktree remove --force`, anywhere (it can destroy work).

This is mistake prevention for agents, not an adversarial security
boundary. The documented fail-open cases (a miss means an allow, never a
wrong block): unparseable stdin; an undetectable primary root; unknown
tool names; a missing `cwd` in the payload; a `cd` target that cannot be
resolved statically (variables, substitutions); commands inside
subshells/command substitutions; and commands with unbalanced quotes.
The owner escape hatch AGENT_LIFECYCLE_ALLOW_PRIMARY=1 lifts only the
primary-checkout rules — never the force-push or forced-removal blocks.
"""

import json
import os
import re
import shlex
import sys

FILE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}

# Deny these outright when they run against the primary checkout.
MUTATING_GIT = {
    "add", "commit", "merge", "rebase", "cherry-pick", "revert", "am",
    "apply", "reset", "restore", "switch", "checkout", "stash", "clean",
    "mv", "rm", "pull", "gc", "repack", "update-ref", "replace",
    "filter-branch", "prune",
}

# Deny these in the primary checkout only with the listed mutating
# arguments — their bare/read forms are everyday inspection.
CONDITIONAL_GIT = {
    "config": None,  # special-cased: read flags allow
    "branch": {"-D", "-d", "--delete", "-m", "-M", "--move", "-c", "-C",
               "--copy", "--set-upstream-to", "--unset-upstream"},
    "tag": {"-d", "--delete"},
    "reflog": {"expire", "delete"},
    "remote": {"add", "remove", "rm", "rename", "set-url", "set-head",
               "set-branches", "prune"},
    "submodule": {"update", "add", "deinit", "sync", "absorbgitdirs",
                  "set-url", "set-branch"},
    "symbolic-ref": None,  # special-cased: bare read allows
}

CONFIG_READ_FLAGS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch",
                     "--list", "-l", "--show-origin", "--show-scope"}

# Plain shell commands that write files: denied when a *written* path
# (resolved against the effective directory) lands inside the primary
# checkout. For copy-like commands only the destination (last positional)
# is written — sources are reads, so `cp <primary>/f /tmp/x` stays
# allowed. `mv` is not copy-like: it deletes its source, so every
# argument counts. `rm /tmp/x` from a primary cwd also stays allowed:
# arguments that don't resolve into the primary checkout never match.
SHELL_WRITERS_ALL_ARGS = {"rm", "rmdir", "touch", "mkdir", "truncate", "tee",
                          "mv"}
SHELL_WRITERS_DEST_ONLY = {"cp", "ln", "install"}

GIT_VALUE_FLAGS = {"-C", "-c", "--config-env", "--namespace", "--exec-path"}

SEPARATORS = {"&&", "||", ";", "|", "&", "\n"}

START_HINT = "scripts/agent-lifecycle.sh start <branch>  (fetches, then creates an isolated worktree)"

PATCH_HEADER = re.compile(
    r"^\*\*\* (?:Update|Add|Delete) File: (.+)$|^\*\*\* Move to: (.+)$",
    re.MULTILINE,
)


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


def primary_override():
    return os.environ.get("AGENT_LIFECYCLE_ALLOW_PRIMARY") == "1"


def deny_primary(fact):
    if primary_override():
        return
    deny(fact, "agents may inspect the primary checkout but never mutate it",
         START_HINT)


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


def resolve_dir(base, target):
    """Resolve target against base; None when it cannot be known statically."""
    if target is None or target.startswith("-") or "$" in target or "`" in target:
        return None
    if os.path.isabs(target):
        return target
    if base is None:
        return None
    return os.path.join(base, target)


RESET = ["__RESET__"]


def token_segments(command):
    """Quote-aware segmentation: shlex-tokenize with punctuation_chars so
    `;`/`|`/`&`/`(`/`)` split even when unspaced, then cut on separator
    tokens. A `)` emits a RESET sentinel (a subshell's `cd` must not leak
    into later segments). Unbalanced quotes fail open (documented)."""
    try:
        lex = shlex.shlex(command, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        return []
    segments, current = [], []
    for tok in tokens:
        # `tok and ...`: an empty argument (`sed -i ''`) is an argument, not a
        # separator — set("") is a subset of every set, so an unguarded test
        # would cut the segment there and drop the paths that follow.
        if tok in SEPARATORS or (tok and set(tok) <= set("&|;")):
            if current:
                segments.append(current)
            current = []
        elif tok == "(" or (tok and set(tok) <= set("()")):
            if current:
                segments.append(current)
            current = []
            if ")" in tok:
                segments.append(RESET)
        elif tok == ")":
            if current:
                segments.append(current)
            current = []
            segments.append(RESET)
        else:
            current.append(tok)
    if current:
        segments.append(current)
    return segments


def parse_git(tokens):
    """For a segment invoking git directly, return
    (subcommand, rest_tokens, c_chain, explicit_dirs); else None.
    c_chain is the ordered list of -C targets; explicit_dirs collects
    --git-dir/--work-tree values (either flag form)."""
    if not tokens or os.path.basename(tokens[0]) != "git":
        return None
    c_chain, explicit_dirs = [], []
    i = 1
    while i < len(tokens):
        t = tokens[i]
        if t == "-C" and i + 1 < len(tokens):
            c_chain.append(tokens[i + 1])
            i += 2
        elif t.startswith("-C") and len(t) > 2:
            c_chain.append(t[2:])
            i += 1
        elif t in ("--git-dir", "--work-tree") and i + 1 < len(tokens):
            explicit_dirs.append(tokens[i + 1])
            i += 2
        elif t.startswith("--git-dir=") or t.startswith("--work-tree="):
            explicit_dirs.append(t.split("=", 1)[1])
            i += 1
        elif t in GIT_VALUE_FLAGS and i + 1 < len(tokens):
            i += 2
        elif t.startswith("-"):
            i += 1
        else:
            return t, tokens[i + 1:], c_chain, explicit_dirs
    return None


def is_short_flag_with(tokens, letter):
    return any(re.fullmatch(rf"-[a-zA-Z]*{letter}[a-zA-Z]*", t) for t in tokens)


def check_push(seg_text, rest):
    if any(t == "--force" or t.startswith("--force-with-lease")
           or t.startswith("--force-if-includes") for t in rest) \
            or is_short_flag_with([t for t in rest if re.fullmatch(r"-[a-zA-Z]+", t)], "f"):
        deny(
            f"a force push: `{seg_text}`",
            "published or shared history is never rewritten unattended; plain pushes only",
            "push without force; if the branch truly needs rewriting, ask the owner first",
        )
    if any(not t.startswith("-") and (t.startswith("+") or t.startswith(":")) for t in rest):
        deny(
            f"a forced or deleting refspec: `{seg_text}`",
            "`+refspec` force-updates and `:refspec` deletes remote refs; both are owner actions",
            "push a plain refspec (`git push origin HEAD`); ask the owner for rewrites or deletions",
        )
    if any(t in ("--delete", "--mirror", "--prune") for t in rest) or is_short_flag_with(
            [t for t in rest if re.fullmatch(r"-[a-zA-Z]+", t)], "d"):
        deny(
            f"a remote-deleting, pruning, or mirror push: `{seg_text}`",
            "deleting remote refs — including via `--prune`, which removes every remote ref absent locally — is an owner action",
            "leave remote refs in place; ask the owner to delete branches",
        )


def conditional_mutates(sub, rest):
    if sub == "config":
        return not any(t in CONFIG_READ_FLAGS for t in rest)
    if sub == "symbolic-ref":
        # bare `symbolic-ref NAME` reads; a second non-flag arg writes
        positional = [t for t in rest if not t.startswith("-")]
        return len(positional) >= 2 or "--delete" in rest or "-d" in rest
    if sub in ("branch", "tag"):
        flagged = CONDITIONAL_GIT[sub]
        if any(t in flagged or t in ("-f", "--force")
               or t.startswith("--set-upstream-to=") for t in rest):
            return True
        # A positional argument without a listing/filter flag creates or
        # moves a ref (`git branch scratch`, `git tag v1`); with one it is
        # a pattern or commit to filter by. `-a` lists for branch but
        # annotates (creates) for tag, so the listing set is per-command.
        listing = ("--list", "--contains", "--no-contains", "--merged",
                   "--no-merged", "--points-at", "--sort", "--format",
                   "--column")
        if any(t == "-l" or t.startswith(listing)
               or (sub == "branch" and t in ("-a", "--all", "-r", "--remotes",
                                             "-v", "-vv", "--verbose",
                                             "--show-current"))
               or (sub == "tag" and t.startswith("-n"))
               for t in rest):
            return False
        return any(not t.startswith("-") for t in rest)
    flagged = CONDITIONAL_GIT.get(sub) or set()
    return any(t in flagged for t in rest)


def path_args_hit_primary(tokens, effective, primary, must_exist=False):
    for t in tokens:
        # An empty argument is not a path; joining it would resolve to the
        # effective directory itself and block an unrelated command.
        if not t or t.startswith("-"):
            continue
        resolved = t if os.path.isabs(t) else (
            os.path.join(effective, t) if effective else None)
        if resolved is None:
            continue
        if must_exist and not os.path.exists(resolved):
            continue
        if inside(resolved, primary):
            return resolved
    return None


def check_plain_writers(seg, seg_text, effective, primary):
    head = os.path.basename(seg[0])
    hit = None
    if head in SHELL_WRITERS_ALL_ARGS:
        hit = path_args_hit_primary(seg[1:], effective, primary)
    elif head in SHELL_WRITERS_DEST_ONLY:
        positionals = [t for t in seg[1:] if not t.startswith("-")]
        if positionals:
            hit = path_args_hit_primary(positionals[-1:], effective, primary)
    elif head == "sed" and any(t == "-i" or t.startswith("-i") for t in seg[1:]):
        # The sed expression also looks like a relative path; only count
        # arguments that exist as files so `s/a/b/` can't false-match.
        hit = path_args_hit_primary(seg[1:], effective, primary, must_exist=True)
    if hit:
        deny_primary(f"`{seg_text}` writing {hit}, inside the primary checkout at {primary}")

    for i, tok in enumerate(seg):
        if tok in (">", ">>") and i + 1 < len(seg):
            target = seg[i + 1]
            resolved = target if os.path.isabs(target) else (
                os.path.join(effective, target) if effective else None)
            if resolved and inside(resolved, primary):
                deny_primary(f"a shell redirection writing {resolved}, inside the primary checkout at {primary}")


def worktree_add_lacks_base(rest):
    if "add" not in rest:
        return False
    after = rest[rest.index("add") + 1:]
    positionals, skip = [], False
    for t in after:
        if skip:
            skip = False
            continue
        if t in ("-b", "-B", "--reason", "--orphan"):
            skip = True
        elif t.startswith("-"):
            continue
        else:
            positionals.append(t)
    return len(positionals) < 2


def check_bash(command, cwd, primary):
    effective = cwd or None
    for seg in token_segments(command):
        if seg == RESET:
            effective = None
            continue
        seg_text = " ".join(seg)
        if seg and seg[0] in ("cd", "pushd"):
            effective = resolve_dir(effective, seg[1] if len(seg) > 1 else None)
            continue

        parsed = parse_git(seg)
        if parsed is None:
            check_plain_writers(seg, seg_text, effective, primary)
            continue
        sub, rest, c_chain, explicit_dirs = parsed

        if sub == "worktree" and worktree_add_lacks_base(rest):
            deny(
                f"`git worktree add` without an explicit base commit: `{seg_text}`",
                "an implicit-HEAD worktree silently inherits a possibly stale base",
                "use `scripts/agent-lifecycle.sh start <branch>` (fetches first), or name the base commit explicitly",
            )

        if sub == "push":
            check_push(seg_text, rest)

        if sub == "worktree" and "remove" in rest and (
                "--force" in rest
                or is_short_flag_with([t for t in rest if re.fullmatch(r"-[a-zA-Z]+", t)], "f")):
            deny(
                f"`git worktree remove --force`: `{seg_text}`",
                "forced worktree removal can destroy uncommitted or unpushed work",
                "run `scripts/agent-lifecycle.sh close <path>` — it proves nothing is lost, then removes without force",
            )

        # Where does this git invocation actually operate?
        targets = []
        git_dir = effective
        for c in c_chain:
            git_dir = resolve_dir(git_dir, c)
        if git_dir is not None:
            targets.append(git_dir)
        for d in explicit_dirs:
            resolved = resolve_dir(effective, d)
            if resolved is not None:
                targets.append(resolved)

        hits_primary = any(inside(t, primary) for t in targets)
        if not hits_primary:
            continue
        if sub in MUTATING_GIT:
            deny_primary(f"`git {sub}` running against the primary checkout at {primary}")
        elif sub in CONDITIONAL_GIT and conditional_mutates(sub, rest):
            deny_primary(f"`git {sub} {' '.join(rest[:3])}` mutating the primary checkout at {primary}")


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
