#!/usr/bin/env bash
set -euo pipefail

# NOTE: This is a dev-only script, intended for use by maintainers of this repo.
# It is not a supported installer. Modifications to it — or requests for
# modifications — will not be approved.
#
# Links all non-deprecated skills in the repository into the local skill
# directories used by each agent harness:
#   - ~/.claude/skills  — Claude Code
#   - ~/.agents/skills  — Codex and other Agent Skills-compatible harnesses
# Repo-owned entries are symlinks, so a `git pull` keeps existing links current.
# Re-run this script after adding, removing, or renaming a skill.

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
DESTS=("$HOME/.claude/skills" "$HOME/.agents/skills")

# Resolve a path for ownership checks even when its final components no longer
# exist. Existing ancestors are resolved physically so a symlink inside the
# repo that leads elsewhere is not mistaken for a repo-owned target.
resolve_for_comparison() {
  local candidate="$1"
  local suffix=""
  local base
  local parent
  local resolved

  while [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; do
    base="$(basename "$candidate")"
    parent="$(dirname "$candidate")"
    [ "$parent" != "$candidate" ] || return 1
    suffix="/$base$suffix"
    candidate="$parent"
  done

  if [ -d "$candidate" ]; then
    resolved="$(cd "$candidate" 2>/dev/null && pwd -P)" || return 1
    printf '%s%s\n' "$resolved" "$suffix"
    return
  fi

  parent="$(dirname "$candidate")"
  resolved="$(cd "$parent" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s%s\n' "$resolved" "$(basename "$candidate")" "$suffix"
}

link_points_into_repo() {
  local link="$1"
  local raw_target
  local candidate
  local resolved

  raw_target="$(readlink "$link")" || return 1
  case "$raw_target" in
    /*) candidate="$raw_target" ;;
    *) candidate="$(dirname "$link")/$raw_target" ;;
  esac

  resolved="$(resolve_for_comparison "$candidate")" || return 1
  case "$resolved" in
    "$REPO"|"$REPO"/*) return 0 ;;
    *) return 1 ;;
  esac
}

prune_dangling_repo_links() {
  local dest="$1"
  local link

  # Include normal and hidden direct children without descending into real
  # skill directories, which the script does not own.
  for link in "$dest"/* "$dest"/.[!.]* "$dest"/..?*; do
    [ -L "$link" ] || continue
    [ ! -e "$link" ] || continue
    link_points_into_repo "$link" || continue

    rm "$link"
    echo "pruned dangling link $link"
  done
}

# Collect the repo's skills once, link into every destination.
names=()
srcs=()
while IFS= read -r -d '' skill_md; do
  src="$(dirname "$skill_md")"
  names+=("$(basename "$src")")
  srcs+=("$src")
done < <(find "$REPO/skills" -name SKILL.md -not -path '*/node_modules/*' -not -path '*/deprecated/*' -print0)

had_conflict=0
for DEST in "${DESTS[@]}"; do
  # If $DEST is a symlink that resolves into this repo, we'd end up writing the
  # per-skill symlinks back into the repo's own skills/ tree. Detect and bail
  # out instead of polluting the working copy.
  if [ -L "$DEST" ]; then
    resolved="$(readlink -f "$DEST")"
    case "$resolved" in
      "$REPO"|"$REPO"/*)
        echo "error: $DEST is a symlink into this repo ($resolved)." >&2
        echo "Remove it (rm \"$DEST\") and re-run; the script will recreate it as a real dir." >&2
        exit 1
        ;;
    esac
  fi

  mkdir -p "$DEST"
  prune_dangling_repo_links "$DEST"

  for i in "${!names[@]}"; do
    name="${names[$i]}"
    src="${srcs[$i]}"
    target="$DEST/$name"

    if [ -L "$target" ]; then
      if ! link_points_into_repo "$target"; then
        echo "error: preserving unrelated symlink at $target" >&2
        had_conflict=1
        continue
      fi
    elif [ -e "$target" ]; then
      echo "error: preserving non-symlink entry at $target" >&2
      had_conflict=1
      continue
    fi

    ln -sfn "$src" "$target"
    echo "linked $name -> $src ($DEST)"
  done
done

if [ "$had_conflict" -ne 0 ]; then
  echo "error: some skills were not linked because unrelated entries already exist" >&2
  exit 1
fi
