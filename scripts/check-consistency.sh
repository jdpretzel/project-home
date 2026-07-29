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
    # Match the backticked `/name` form the router actually uses — a bare
    # substring would count a skill merely mentioned in passing as routed.
    if grep -q '^disable-model-invocation: true' "$dir/SKILL.md" \
       && [ "$name" != "ask-matt" ]; then
      grep -q '`/'"$name"'`' skills/engineering/ask-matt/SKILL.md \
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
# Scope, stated as what IS scanned rather than as a list of exemptions — the
# surfaces a reader or a model acts on, which must therefore describe the
# system as it currently behaves. `.out-of-scope/` is in scope precisely
# because triage reads it at runtime to surface prior rejections, so a stale
# entry there is a wrong answer given to a user, not an archive.
#
# Everything else is unscanned, including `.agents/` and CHANGELOG.md: naming
# what was removed is the whole job of a decision record, and of CONTEXT.md's
# _Avoid_ lists and flagged ambiguities.
SCAN=(skills/engineering skills/productivity docs .out-of-scope README.md CLAUDE.md)

stale=$(grep -rn \
  -e 'issue-tracker-github' -e 'issue-tracker-gitlab' -e 'issue-tracker-local' \
  -e 'configured tracker' -e 'tracker-specific' -e 'local-markdown tracker' \
  -e 'a real tracker' -e 'real issue tracker' -e 'local tracker' \
  -e 'issue-tracker wiring' -e 'scratch/<feature' \
  -e 'setup-matt-pocock-skills' -e 'glab ' \
  --include='*.md' "${SCAN[@]}" 2>/dev/null)
if [ -n "$stale" ]; then
  while IFS= read -r line; do report "stale reference: $line"; done <<<"$stale"
fi

# docs/agents/ gets its own pass: setup-project-home is the one file allowed to
# name it, because it offers to clean up leftovers from its own older versions.
agents_dir=$(grep -rn 'docs/agents' --include='*.md' "${SCAN[@]}" 2>/dev/null \
  | grep -v '^skills/engineering/setup-project-home/SKILL.md:')
if [ -n "$agents_dir" ]; then
  while IFS= read -r line; do report "retired docs/agents/ convention: $line"; done <<<"$agents_dir"
fi

# Behaviours the spec required verifying that no manifest can express. These are
# assertions about the prose, which is where the behaviour actually lives.
#
# Each anchor must be a phrase that appears EXACTLY ONCE in its file, and only
# in the passage carrying the behaviour. An anchor that also occurs elsewhere
# passes when the passage is deleted, which is a check that cannot fail — worse
# than no check, because it reports safety it never established.
echo "Required behaviours are still specified"
setup=skills/engineering/setup-project-home/SKILL.md
way=skills/engineering/wayfinder/SKILL.md
assert_once() { # file, anchor, description
  case "$(grep -cF "$2" "$1")" in
    1) ;;
    0) report "$1: $3 — anchor gone" ;;
    *) report "$1: anchor for $3 is no longer unique; the check cannot fail" ;;
  esac
}
assert_once "$setup" 'gh auth status' "preflight auth check"
assert_once "$setup" 'hasIssuesEnabled' "preflight Issues-capability check"
assert_once "$setup" 'stop and say which' "GitHub loud stop"
assert_once "$setup" 'No labels, no block' "triage-off branch"
assert_once "$setup" 'Reconcile them against' "triage-on branch"
assert_once "$way" 'stop and say which one' "GitHub loud stop"
assert_once "$way" '**No sub-issues**' "task-list degradation"
assert_once "$way" '**No dependencies**' "Blocked-by degradation"
for s in to-spec to-tickets; do
  assert_once "skills/engineering/$s/SKILL.md" \
    "don't fail the publish over a label" "no-triage label branch"
done

if [ "$fail" -eq 0 ]; then
  echo "All consistency checks passed."
else
  echo "Consistency checks FAILED."
fi
exit "$fail"
