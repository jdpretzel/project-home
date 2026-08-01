#!/usr/bin/env python3
"""PreToolUse guard for the agent repository lifecycle (ADR 0004).

One policy, two registrations: .claude/settings.json (Claude Code) and
.codex/hooks.json (Codex) both run this script before file-edit and shell
tools. Both harnesses honour the same contract: exit 0 allows the call,
exit 2 blocks it with the stderr text as the reason.

The guard is a small footgun catch — not a command interpreter and not a
security boundary. It denies only operations that are both consequential
and reliably detectable at the git-verb level, and every denial names the
detected fact, the violated rule, and the exact safe next action:

  1. file edits (and apply_patch targets) inside the primary checkout;
  2. mutating git verbs run against the primary checkout — via cwd, -C,
     --git-dir/--work-tree, a GIT_DIR/GIT_WORK_TREE environment prefix,
     or a `cd` earlier in the command;
  3. writes to state every worktree shares with the primary — `config`
     writes (except `--worktree` scope, outside the primary) and
     `remote` rewrites — from the primary or any linked worktree;
  4. recovery-destroying commands: `reflog expire|delete` and `gc`
     against the primary, force/deleting/pruning pushes anywhere, and
     any `git worktree remove` (it skips close's loss proofs; even
     unforced removal deletes ignored files);
  5. pushes beyond the publication contract of exactly one ordinary
     topic branch: default-branch destinations, tag destinations,
     `--all`/`--branches`/`--tags`/`--follow-tags`, multiple refspecs;
  6. `git worktree add` without an explicit base commit (use the
     lifecycle's `start`, which fetches first).

Everything else deliberately fails open — a miss must be an allow, never
a wrong block, and partial coverage of arbitrary shell is worse than its
honest absence. Deliberately uncovered: plain shell writes into the
primary (`rm`, `cp`, `sed -i`, redirections, interpreters); local ref
surgery (`branch`, `tag`, `notes`, `bisect`); fetches with write
refspecs; `clone` and `format-patch` destinations; and the parsing gaps
(unparseable stdin, an undetectable primary root, unknown tools, a
missing payload `cwd`, statically unresolvable `cd` targets, subshell
and command-substitution contents, flagged runner invocations,
unbalanced quotes). That damage is local and recoverable — from the
remote, the reflog, and plain `git status` visibility — which is exactly
why the commands that destroy those recovery paths stay in the denied
set above. The real boundaries are worktree isolation, close's loss
proofs, and GitHub's rulesets.

The owner escape hatch AGENT_LIFECYCLE_ALLOW_PRIMARY=1 lifts only the
primary-checkout and shared-state rules — never the push or
worktree-removal blocks.
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

CONFIG_READ_FLAGS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch",
                     "--list", "-l", "--show-origin", "--show-scope"}

REMOTE_WRITE_SUBCOMMANDS = {"add", "remove", "rm", "rename", "set-url",
                            "set-head", "set-branches", "prune"}

GIT_VALUE_FLAGS = {"-C", "-c", "--config-env", "--namespace", "--exec-path"}

# `git push` flags that take a separate value; without consuming them the
# value would be misread as the remote positional and a plain topic push
# could be wrongly blocked.
PUSH_VALUE_FLAGS = {"-o", "--push-option", "--receive-pack", "--exec", "--repo"}

SEPARATORS = {"&&", "||", ";", "|", "&", "\n"}

# Runners that execute their trailing arguments as the real command:
# `nohup git push --force` must be classified as `git push --force`. Only
# bare runner words (plus a `--` terminator) are peeled; flagged forms
# (`nice -n 10 ...`) fail open.
RUNNER_PREFIXES = {"command", "exec", "nohup", "time", "nice"}

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


def deny_shared(fact):
    # Same override as deny_primary: shared state IS primary .git state, so
    # the owner's inline escape hatch covers it.
    if primary_override():
        return
    deny(fact,
         "linked worktrees share the primary repository's config and refs; "
         "mutating shared state is primary-checkout mutation",
         "use per-worktree scope (`git config --worktree`) for worktree-local "
         "settings; ask the owner before changing shared config or remotes")


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


def linked_worktree_of(path, primary):
    """True when path lies inside a linked worktree of the primary repo —
    such a worktree shares the primary's .git/config and refs, so shared-state
    mutations from it are primary mutations. Walks up to the first .git entry
    (a .git *file* whose gitdir points into <primary>/.git/worktrees/)."""
    current = os.path.realpath(path)
    while True:
        dot_git = os.path.join(current, ".git")
        if os.path.isdir(dot_git):
            return False  # a full repository of its own
        if os.path.isfile(dot_git):
            try:
                with open(dot_git, encoding="utf-8") as f:
                    content = f.read().strip()
            except OSError:
                return False
            if content.startswith("gitdir:"):
                gitdir = content[len("gitdir:"):].strip()
                marker = f"{os.sep}.git{os.sep}worktrees{os.sep}"
                idx = gitdir.find(marker)
                if idx != -1:
                    return os.path.realpath(gitdir[:idx]) == primary
            return False
        parent = os.path.dirname(current)
        if parent == current:
            return False
        current = parent


def remote_default_branch(primary, remote):
    """The branch the remote's HEAD names, read from the primary checkout's
    refs/remotes/<remote>/HEAD symref file; None when unknowable (URL remotes,
    reftable storage, no such file) — an unknowable default fails open."""
    head = os.path.join(primary, ".git", "refs", "remotes", remote, "HEAD")
    try:
        with open(head, encoding="utf-8") as f:
            content = f.read().strip()
    except OSError:
        return None
    prefix = f"ref: refs/remotes/{remote}/"
    if content.startswith(prefix):
        return content[len(prefix):]
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


def push_remote_and_refspecs(rest):
    """(remote, refspecs): the repository may arrive as the first positional
    or via --repo, in which case every positional is a refspec."""
    repo, out, i = None, [], 0
    while i < len(rest):
        t = rest[i]
        if t in PUSH_VALUE_FLAGS and i + 1 < len(rest):
            if t == "--repo":
                repo = rest[i + 1]
            i += 2
            continue
        if t.startswith("--repo="):
            repo = t.split("=", 1)[1]
            i += 1
            continue
        if t.startswith("-"):
            i += 1
            continue
        out.append(t)
        i += 1
    if repo is None and out:
        repo, out = out[0], out[1:]
    return repo, out


def check_push(seg_text, rest, primary):
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
    # The publication contract is exactly one ordinary topic branch per
    # push: branch-sweeping and tag-publishing forms are owner actions.
    if any(t in ("--all", "--branches", "--tags", "--follow-tags")
           for t in rest):
        deny(
            f"a branch-sweeping or tag-publishing push: `{seg_text}`",
            "publication is exactly one ordinary topic branch per push; pushing all branches or any tags is an owner action",
            "push the one topic branch (`git push origin HEAD`); ask the owner about tags or bulk publication",
        )
    remote, refspecs = push_remote_and_refspecs(rest)
    if len(refspecs) > 1:
        deny(
            f"multiple refspecs in one push: `{seg_text}`",
            "publication is exactly one ordinary topic branch per push",
            "push one refspec at a time; ask the owner if several branches genuinely need publishing",
        )
    # An ordinary refspec can still land on the remote's default branch
    # (`git push origin HEAD:main`, `git push origin main`) or publish a
    # tag (`refs/tags/...` destination). The destination is the part after
    # `:`, or the whole refspec when there is none; an unknowable default
    # branch or a bare/`HEAD` destination fails open, as does an
    # unqualified name that happens to resolve to a local tag.
    if remote is not None:
        default = remote_default_branch(primary, remote)
        for spec in refspecs:
            dest = spec.split(":", 1)[1] if ":" in spec else spec
            if dest.startswith("refs/tags/"):
                deny(
                    f"a push publishing a tag: `{seg_text}`",
                    "tag publication is an owner action",
                    "push the topic branch only; ask the owner to create or push tags",
                )
            if dest.startswith("refs/heads/"):
                dest = dest[len("refs/heads/"):]
            if default and dest == default:
                deny(
                    f"a push targeting the remote default branch '{default}': `{seg_text}`",
                    "default-branch pushes are the owner's; agent work lands by PR",
                    "push a topic branch (`git push origin HEAD`) and open a draft PR",
                )


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
    made_dirs = set()
    for seg in token_segments(command):
        if seg == RESET:
            effective = None
            continue
        seg_text = " ".join(seg)
        # Leading VAR=value assignments would hide the real command word —
        # and Git's own repository-selection variables re-target it
        # (`GIT_DIR=<primary>/.git git reset --hard`), so their values count
        # as operating directories.
        env_dirs = []
        while seg and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", seg[0]):
            var, val = seg[0].split("=", 1)
            if var in ("GIT_DIR", "GIT_WORK_TREE"):
                resolved = resolve_dir(effective, val)
                if resolved is not None:
                    env_dirs.append(resolved)
            seg = seg[1:]
        while seg and (os.path.basename(seg[0]) in RUNNER_PREFIXES
                       or seg[0] == "--"):
            seg = seg[1:]
        if not seg or seg[0].startswith("-"):
            continue  # a flagged runner form: documented fail-open
        if seg[0] in ("cd", "pushd"):
            target = resolve_dir(effective, seg[1] if len(seg) > 1 else None)
            if target is None:
                effective = None  # statically unresolvable: documented fail-open
            elif os.path.isdir(os.path.realpath(target)) \
                    or os.path.normpath(target) in made_dirs:
                effective = target
            # else: the cd will fail at runtime and the shell keeps its
            # directory (`cd /missing; git commit` still runs here), so the
            # effective directory must not change either.
            continue
        if os.path.basename(seg[0]) == "mkdir":
            # A directory this very command creates is a valid later cd
            # target (`mkdir -p x && cd x && ...`) even though it does not
            # exist at guard time.
            for t in seg[1:]:
                r = resolve_dir(effective, t)
                if r is not None:
                    made_dirs.add(os.path.normpath(r))

        parsed = parse_git(seg)
        if parsed is None:
            continue
        sub, rest, c_chain, explicit_dirs = parsed

        if sub == "worktree" and worktree_add_lacks_base(rest):
            deny(
                f"`git worktree add` without an explicit base commit: `{seg_text}`",
                "an implicit-HEAD worktree silently inherits a possibly stale base",
                "use `scripts/agent-lifecycle.sh start <branch>` (fetches first), or name the base commit explicitly",
            )

        if sub == "push":
            check_push(seg_text, rest, primary)

        # Any `worktree remove`, forced or not: Git happily removes a clean
        # worktree that still holds ignored files, and nothing here has run
        # close's unpushed/dirty/ignored loss proofs.
        if sub == "worktree" and "remove" in rest:
            deny(
                f"`git worktree remove`: `{seg_text}`",
                "worktree removal outside the lifecycle skips close's loss proofs; even unforced removal deletes ignored files",
                "run `scripts/agent-lifecycle.sh close <path>` — it proves nothing is lost, then removes",
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
        targets.extend(env_dirs)

        hits_primary = any(inside(t, primary) for t in targets)
        in_linked = not hits_primary and \
            any(linked_worktree_of(t, primary) for t in targets)

        if hits_primary and sub in MUTATING_GIT:
            deny_primary(f"`git {sub}` running against the primary checkout at {primary}")
        elif hits_primary and sub == "reflog" \
                and rest[:1] and rest[0] in ("expire", "delete"):
            # The reflog is the recovery net that makes the guard's other
            # fail-opens acceptable; destroying it is never a fail-open.
            deny_primary(f"`git reflog {rest[0]}` destroying recovery state in the primary checkout at {primary}")
        elif sub == "config" \
                and not any(t in CONFIG_READ_FLAGS for t in rest):
            # config writes are shared across every linked worktree (except
            # --worktree scope, which is worktree-local — but from the
            # primary even that writes the primary's own state).
            if hits_primary:
                deny_primary(f"`git config {' '.join(rest[:3])}` mutating the primary checkout at {primary}")
            elif in_linked and "--worktree" not in rest:
                deny_shared(f"`git config {' '.join(rest[:3])}` mutating shared repository state from a linked worktree of {primary}")
        elif sub == "remote" \
                and any(t in REMOTE_WRITE_SUBCOMMANDS for t in rest):
            if hits_primary:
                deny_primary(f"`git remote {' '.join(rest[:2])}` mutating the primary checkout at {primary}")
            elif in_linked:
                deny_shared(f"`git remote {' '.join(rest[:2])}` mutating shared repository state from a linked worktree of {primary}")


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
