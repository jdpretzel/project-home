#!/usr/bin/env bash
set -uo pipefail

# NOTE: This is a dev-only script, intended for use by maintainers of this repo.
#
# PROSE LINT, NOT BEHAVIOURAL PROOF. Everything here is grep over Markdown. It
# can tell you a skill still *says* the right thing; it can never tell you a
# skill still *does* the right thing. Behaviour is verified by running the
# skills against real repositories — see the fresh-context scenarios recorded
# in the pull request for ADR 0003.
#
# Scope is deliberately narrow: the tracker invariants from
# .agents/adr/0003-github-is-the-supported-tracker.md.
#
#   1. Nothing references the retired tracker abstraction.
#   2. The behaviours that decision requires are still specified.
#
# Enforcing the broader CLAUDE.md rules — every promoted skill indexed in
# README.md / the bucket README / plugin.json / docs, and every user-invoked
# skill routed by ask-matt — is deliberately NOT here. A currency mechanism for
# those indexes is the open question in "The router and system legibility"
# (issue #13), and quietly shipping one inside a tracker PR would settle that
# decision by accident.
#
# `claude plugin validate .` checks the manifests parse. Run both.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

fail=0
report() { printf '  ✗ %s\n' "$1"; fail=1; }

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
