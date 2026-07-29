#!/usr/bin/env bash
set -uo pipefail

# NOTE: This is a dev-only script, intended for use by maintainers of this repo.
#
# Checks the invariants CLAUDE.md states but nothing enforces — the ones whose
# failure mode is an index that lies rather than a build that breaks:
#
#   1. Every promoted skill is listed in README.md, its bucket README,
#      plugin.json, and has a docs page.
#   2. No non-promoted skill leaks into README.md or plugin.json.
#   3. Every user-invoked promoted skill is routed by ask-matt.
#   4. Nothing references the retired tracker abstraction (ADR 0003).
#
# `claude plugin validate .` checks the manifests parse. This checks they tell
# the truth. Run both.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

fail=0
report() { printf '  ✗ %s\n' "$1"; fail=1; }

echo "Promoted skills — indexes, manifest, docs"
for bucket in engineering productivity; do
  for dir in "skills/$bucket"/*/; do
    [ -f "$dir/SKILL.md" ] || continue
    name="$(basename "$dir")"
    grep -q "skills/$bucket/$name/SKILL.md" README.md \
      || report "$name: missing from README.md"
    grep -q "($name/SKILL.md\|(./$name/SKILL.md" "skills/$bucket/README.md" \
      || report "$name: missing from skills/$bucket/README.md"
    grep -q "\"./skills/$bucket/$name\"" .claude-plugin/plugin.json \
      || report "$name: missing from .claude-plugin/plugin.json"
    [ -f "docs/$bucket/$name.md" ] \
      || report "$name: missing docs page docs/$bucket/$name.md"
    # User-invoked skills are the router's remit; model-invoked ones are not.
    if grep -q '^disable-model-invocation: true' "$dir/SKILL.md" \
       && [ "$name" != "ask-matt" ]; then
      grep -q "/$name" skills/engineering/ask-matt/SKILL.md \
        || report "$name: user-invoked but not routed by ask-matt"
    fi
  done
done

echo "Non-promoted skills — must not be shipped"
for bucket in misc personal in-progress deprecated; do
  [ -d "skills/$bucket" ] || continue
  for dir in "skills/$bucket"/*/; do
    [ -f "$dir/SKILL.md" ] || continue
    name="$(basename "$dir")"
    grep -q "skills/$bucket/$name" README.md \
      && report "$name: non-promoted but referenced in README.md"
    grep -q "\"./skills/$bucket/$name\"" .claude-plugin/plugin.json \
      && report "$name: non-promoted but listed in plugin.json"
  done
done

echo "Retired tracker abstraction (ADR 0003)"
# Three deliberate exemptions, all the same shape — places whose job is to name
# what was removed:
#   - .agents/adr/ and CHANGELOG.md are decision records.
#   - CONTEXT.md is the glossary; its _Avoid_ lists and flagged ambiguities
#     exist precisely to name retired vocabulary.
#   - setup-project-home names docs/agents/ to offer cleanup of leftovers from
#     its own older versions.
stale=$(grep -rn \
  -e 'issue-tracker-github' -e 'issue-tracker-gitlab' -e 'issue-tracker-local' \
  -e 'docs/agents/issue-tracker' -e 'configured tracker' -e 'tracker-specific' \
  -e 'local-markdown tracker' -e 'setup-matt-pocock-skills' -e 'glab ' \
  --include='*.md' \
  skills/engineering skills/productivity docs README.md CLAUDE.md \
  2>/dev/null | grep -v '^skills/engineering/setup-project-home/SKILL.md')
if [ -n "$stale" ]; then
  while IFS= read -r line; do report "stale reference: $line"; done <<<"$stale"
fi

if [ "$fail" -eq 0 ]; then
  echo "All consistency checks passed."
else
  echo "Consistency checks FAILED."
fi
exit "$fail"
