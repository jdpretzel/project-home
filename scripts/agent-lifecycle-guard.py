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
     via -C, --git-dir/--work-tree, a GIT_DIR/GIT_WORK_TREE environment
     prefix, or a `cd` earlier in the command;
  3. force pushes — flags or `+`/`:`-refspecs — remote deletions, and
     pushes whose refspec destination is the remote's default branch,
     anywhere (published history and the default branch are the owner's);
  4. `git worktree remove`, anywhere (outside `close` it skips the
     dirty/ignored/unpushed loss proofs; ordinary removal still deletes
     ignored files);
  5. shared-state mutations from a linked worktree of the primary —
     `config` writes (except `--worktree` scope), `remote` rewrites, and
     `fetch` refspecs that write outside refs/remotes/ — because linked
     worktrees share the primary repository's config and refs.

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
               "--copy", "--set-upstream-to", "--unset-upstream",
               "--edit-description"},
    "tag": {"-d", "--delete"},
    "reflog": {"expire", "delete"},
    "remote": {"add", "remove", "rm", "rename", "set-url", "set-head",
               "set-branches", "prune"},
    "submodule": {"update", "add", "init", "deinit", "sync",
                  "absorbgitdirs", "set-url", "set-branch"},
    "symbolic-ref": None,  # special-cased: bare read allows
    # `git notes` writes refs/notes/*; list/show forms read.
    "notes": {"add", "append", "copy", "edit", "merge", "remove", "prune"},
    # bisect writes bisect refs/state and checks out candidate commits;
    # its log/terms/visualize forms read.
    "bisect": None,  # special-cased below
    # Plain `fetch` (with or without --prune) converges local remote-tracking
    # refs toward the remote's authoritative state — the lifecycle itself
    # prescribes pruned fetches as evidence hygiene, so it stays allowed
    # everywhere. What a fetch must not do is write outside refs/remotes/:
    # a `src:dst` refspec (or --refmap) can update local branches, and
    # --prune-tags deletes local tags the remote never had.
    "fetch": None,  # special-cased: only ref-writing forms mutate
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

# Options whose separate value is not a written path (`touch -d yesterday`,
# `install -m 644`): consumed before the path scan so the guard stays limited
# to actual write targets. `mv -t DIR` is deliberately absent — its value IS
# a written destination, and mv's all-arguments scan must keep seeing it.
WRITER_VALUE_OPTS = {
    "touch": {"-d", "--date", "-r", "--reference", "-t"},
    "truncate": {"-s", "--size", "-r", "--reference"},
    "mkdir": {"-m", "--mode"},
    "mv": {"-S", "--suffix"},
    "cp": {"-S", "--suffix"},
    "ln": {"-S", "--suffix"},
    "install": {"-m", "--mode", "-o", "--owner", "-g", "--group",
                "-S", "--suffix", "--strip-program"},
    "chmod": {"--reference"},
}

GIT_VALUE_FLAGS = {"-C", "-c", "--config-env", "--namespace", "--exec-path"}

# `git push` flags that take a separate value; without consuming them the
# value would be misread as the remote positional.
PUSH_VALUE_FLAGS = {"-o", "--push-option", "--receive-pack", "--exec", "--repo"}

SEPARATORS = {"&&", "||", ";", "|", "&", "\n"}

# Runners that execute their trailing arguments as the real command:
# `command rm f` must be classified as `rm f`.
RUNNER_PREFIXES = {"command", "exec", "nohup", "time", "nice"}


def peel_runners(seg):
    while seg:
        head = os.path.basename(seg[0])
        if head not in RUNNER_PREFIXES:
            return seg
        rest = seg[1:]
        if head == "command":
            if any(t in ("-v", "-V") for t in rest):
                return []  # describe-only: nothing executes
            while rest and rest[0] == "-p":
                rest = rest[1:]
            if rest and rest[0] == "--":
                rest = rest[1:]
        elif head == "exec":
            while rest and rest[0].startswith("-"):
                if rest[0] == "-a" and len(rest) > 1:
                    rest = rest[2:]
                else:
                    rest = rest[1:]
        elif head == "nice":
            while rest and rest[0].startswith("-"):
                if rest[0] == "-n" and len(rest) > 1:
                    rest = rest[2:]
                else:
                    rest = rest[1:]
        elif head == "time":
            while rest and rest[0] == "-p":
                rest = rest[1:]
        seg = rest
    return seg

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
         "settings; ask the owner before changing shared config, remotes, or refs")


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


def local_tag_exists(primary, name):
    """True when refs/tags/<name> exists in the primary repo (worktrees share
    tag refs) — loose file or packed-refs; reftable storage fails open."""
    if not name or name.startswith("refs/") or "/" in name:
        return False
    if os.path.isfile(os.path.join(primary, ".git", "refs", "tags", name)):
        return True
    try:
        with open(os.path.join(primary, ".git", "packed-refs"),
                  encoding="utf-8") as f:
            for line in f:
                if line.strip().endswith(f" refs/tags/{name}"):
                    return True
    except OSError:
        pass
    return False


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
    # branch or a bare/`HEAD` destination fails open.
    if remote is not None:
        default = remote_default_branch(primary, remote)
        for spec in refspecs:
            dest = spec.split(":", 1)[1] if ":" in spec else spec
            # An unqualified name that resolves to a local tag publishes
            # that tag: rev-parse tries refs/tags/<name> before
            # refs/heads/<name>, so an existing tag wins the refspec.
            if dest.startswith("refs/tags/") or local_tag_exists(primary, dest):
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


def conditional_mutates(sub, rest):
    if sub == "config":
        return not any(t in CONFIG_READ_FLAGS for t in rest)
    if sub == "bisect":
        positional = [t for t in rest if not t.startswith("-")]
        if not positional:
            return False
        return positional[0] not in ("log", "terms", "visualize", "view")
    if sub == "fetch":
        # Only forms that write outside refs/remotes/ mutate: a refspec with
        # a destination elsewhere (updates local branches), --refmap (rewrites
        # where fetched refs land), or --prune-tags (deletes local tags).
        if any(t == "--prune-tags" or t.startswith("--refmap") for t in rest):
            return True
        for t in rest:
            if t.startswith("-") or ":" not in t:
                continue
            if not t.split(":", 1)[1].startswith("refs/remotes/"):
                return True
        return False
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


def writer_args(head, args):
    """Split a writer's arguments into (positionals, target_dir), consuming
    the options whose value is not a written path and capturing a
    `-t`/`--target-directory` destination when present."""
    value_opts = WRITER_VALUE_OPTS.get(head, set())
    positionals, target_dir, i = [], None, 0
    while i < len(args):
        t = args[i]
        if head in SHELL_WRITERS_DEST_ONLY:
            # GNU form: `cp -t DIR SOURCE...` — the directory is the
            # destination and every positional after it is a source.
            if t in ("-t", "--target-directory") and i + 1 < len(args):
                target_dir = args[i + 1]
                i += 2
                continue
            if t.startswith("--target-directory="):
                target_dir = t.split("=", 1)[1]
                i += 1
                continue
        if t in value_opts and i + 1 < len(args):
            i += 2
            continue
        if not t.startswith("-"):
            positionals.append(t)
        i += 1
    return positionals, target_dir


def check_plain_writers(seg, seg_text, effective, primary):
    head = os.path.basename(seg[0])
    hit = None
    if head in SHELL_WRITERS_ALL_ARGS:
        positionals, _ = writer_args(head, seg[1:])
        hit = path_args_hit_primary(positionals, effective, primary)
    elif head == "chmod":
        positionals, _ = writer_args(head, seg[1:])
        # The first positional is the mode (`u+x`, `755`) unless --reference
        # supplies it; the rest are the files whose metadata changes — a
        # tracked executable bit flip dirties the checkout.
        has_ref = any(t == "--reference" or t.startswith("--reference=")
                      for t in seg[1:])
        # A symbolic mode may itself start with a dash (`chmod -w f`); mode
        # letters (ugoa+rwxXst) and option letters (Rcfv) are disjoint, so
        # such a token is the mode operand, already excluded from
        # positionals by its dash.
        dash_mode = any(re.fullmatch(r"-[rwxXstugoa]+", t) for t in seg[1:])
        hit = path_args_hit_primary(
            positionals if has_ref or dash_mode else positionals[1:],
            effective, primary)
    elif head in SHELL_WRITERS_DEST_ONLY:
        positionals, target_dir = writer_args(head, seg[1:])
        if head == "install" and any(t in ("-d", "--directory")
                                     for t in seg[1:]):
            # `install -d DIRECTORY...`: every operand is a directory to
            # create, not sources plus one destination.
            dests = positionals
        elif target_dir is not None:
            dests = [target_dir]
        elif head == "ln" and len(positionals) == 1:
            # One-operand `ln -s /tmp/target` creates basename(target) in
            # the current directory — the operand itself is only read.
            dests = [os.path.join(effective, os.path.basename(positionals[0]))] \
                if effective else []
        else:
            dests = positionals[-1:]
        if dests:
            hit = path_args_hit_primary(dests, effective, primary)
    elif head == "sed" and any(
            t == "--in-place" or t.startswith("--in-place=")
            or (t.startswith("-i") and not t.startswith("--"))
            # combined short flags carry it too: `sed -Ei 's/a/b/' file`
            or (re.fullmatch(r"-[a-zA-Z]+", t) and "i" in t[1:])
            for t in seg[1:]):
        # The sed expression also looks like a relative path; only count
        # arguments that exist as files so `s/a/b/` can't false-match.
        hit = path_args_hit_primary(seg[1:], effective, primary, must_exist=True)
    if hit:
        deny_primary(f"`{seg_text}` writing {hit}, inside the primary checkout at {primary}")

    # Bash's other write redirections tokenize as single punctuation runs:
    # `&>`/`&>>` (stdout+stderr) and `>|` (clobbering).
    for i, tok in enumerate(seg):
        if tok in (">", ">>", "&>", "&>>", ">|") and i + 1 < len(seg):
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
        while seg and seg != RESET \
                and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", seg[0]):
            var, val = seg[0].split("=", 1)
            if var in ("GIT_DIR", "GIT_WORK_TREE"):
                resolved = resolve_dir(effective, val)
                if resolved is not None:
                    env_dirs.append(resolved)
            seg = seg[1:]
        seg = peel_runners(seg)
        if not seg:
            continue
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

        # clone materializes an untracked repository at its destination —
        # the second positional, or a directory derived from the source name.
        if sub == "clone":
            value_flags = {"-b", "--branch", "--depth", "-o", "--origin",
                           "-u", "--upload-pack", "--reference",
                           "--reference-if-able", "--separate-git-dir",
                           "--template", "-c", "--config", "-j", "--jobs",
                           "--filter", "--shallow-since", "--shallow-exclude",
                           "--server-option", "--bundle-uri"}
            pos, i = [], 0
            while i < len(rest):
                t = rest[i]
                if t in value_flags and i + 1 < len(rest):
                    i += 2
                    continue
                if t.startswith("-"):
                    i += 1
                    continue
                pos.append(t)
                i += 1
            dest = None
            if len(pos) >= 2:
                dest = pos[1]
            elif pos:
                name = os.path.basename(pos[0].rstrip("/"))
                dest = name[:-4] if name.endswith(".git") else name
            base = targets[0] if targets else None
            resolved = resolve_dir(base, dest) if dest else None
            if resolved is not None and inside(resolved, primary):
                deny_primary(f"`git clone` creating {resolved}, inside the primary checkout at {primary}")

        # format-patch writes .patch files into its output directory — the
        # effective directory unless --stdout or -o/--output-directory says
        # otherwise.
        if sub == "format-patch" and "--stdout" not in rest:
            out = None
            for i, t in enumerate(rest):
                if t in ("-o", "--output-directory") and i + 1 < len(rest):
                    out = rest[i + 1]
                elif t.startswith("--output-directory="):
                    out = t.split("=", 1)[1]
                elif t.startswith("-o") and len(t) > 2 and not t.startswith("--"):
                    out = t[2:]
            base = targets[0] if targets else None
            dest = resolve_dir(base, out) if out is not None else base
            if dest is not None and inside(dest, primary):
                deny_primary(f"`git format-patch` writing patch files into the primary checkout at {primary}")

        hits_primary = any(inside(t, primary) for t in targets)
        if hits_primary:
            if sub in MUTATING_GIT:
                deny_primary(f"`git {sub}` running against the primary checkout at {primary}")
            elif sub in CONDITIONAL_GIT and conditional_mutates(sub, rest):
                deny_primary(f"`git {sub} {' '.join(rest[:3])}` mutating the primary checkout at {primary}")
        elif sub in ("config", "remote", "fetch") \
                and conditional_mutates(sub, rest) \
                and not (sub == "config" and "--worktree" in rest) \
                and any(linked_worktree_of(t, primary) for t in targets):
            # Linked worktrees share the primary's .git/config and refs:
            # `git config core.hooksPath` or `git remote set-url` from one
            # rewrites owner-controlled shared state all the same.
            deny_shared(f"`git {sub} {' '.join(rest[:3])}` mutating shared repository state from a linked worktree of {primary}")


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
