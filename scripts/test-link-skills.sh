#!/usr/bin/env bash
set -euo pipefail

SOURCE_SCRIPT="$(cd "$(dirname "$0")" && pwd)/link-skills.sh"
TEST_PARENT="${TMPDIR:-/tmp}"
TEST_PARENT="${TEST_PARENT%/}"
TEST_ROOT="$(mktemp -d "$TEST_PARENT/link-skills-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

new_fixture() {
  fixture="$TEST_ROOT/$1"
  mkdir -p "$fixture/repo/scripts" "$fixture/repo/skills/engineering" "$fixture/home"
  cp "$SOURCE_SCRIPT" "$fixture/repo/scripts/link-skills.sh"
  chmod +x "$fixture/repo/scripts/link-skills.sh"
}

add_skill() {
  fixture="$1"
  name="$2"
  mkdir -p "$fixture/repo/skills/engineering/$name"
  printf '%s\n' "# $name" >"$fixture/repo/skills/engineering/$name/SKILL.md"
}

run_linker() {
  fixture="$1"
  HOME="$fixture/home" "$fixture/repo/scripts/link-skills.sh" \
    >"$fixture/link-skills.out" 2>"$fixture/link-skills.err"
}

assert_link_to() {
  link="$1"
  expected="$2"
  [ -L "$link" ] || fail "$link is not a symlink"
  [ "$(readlink "$link")" = "$expected" ] || \
    fail "$link points to $(readlink "$link"), expected $expected"
}

assert_absent() {
  path="$1"
  [ ! -e "$path" ] && [ ! -L "$path" ] || fail "$path still exists"
}

test_adds_new_skills() {
  new_fixture additions
  add_skill "$fixture" alpha

  run_linker "$fixture"

  for harness in .claude .agents; do
    assert_link_to \
      "$fixture/home/$harness/skills/alpha" \
      "$fixture/repo/skills/engineering/alpha"
  done
}

test_prunes_links_after_rename_or_removal() {
  new_fixture rename
  add_skill "$fixture" alpha
  add_skill "$fixture" retired
  run_linker "$fixture"

  mv \
    "$fixture/repo/skills/engineering/alpha" \
    "$fixture/repo/skills/engineering/beta"
  mv \
    "$fixture/repo/skills/engineering/retired" \
    "$fixture/retired-skill"
  ln -s \
    "$fixture/repo/skills/engineering/removed" \
    "$fixture/repo/skills/inner-redirect"
  ln -s \
    "$fixture/repo/skills/inner-redirect" \
    "$fixture/home/.agents/skills/chained-removed"
  run_linker "$fixture"

  for harness in .claude .agents; do
    assert_absent "$fixture/home/$harness/skills/alpha"
    assert_absent "$fixture/home/$harness/skills/retired"
    assert_link_to \
      "$fixture/home/$harness/skills/beta" \
      "$fixture/repo/skills/engineering/beta"
  done
  assert_absent "$fixture/home/.agents/skills/chained-removed"
}

test_preserves_unrelated_skills() {
  new_fixture preservation
  add_skill "$fixture" alpha

  mkdir -p \
    "$fixture/home/.claude/skills/alpha" \
    "$fixture/home/.agents/skills" \
    "$fixture/outside/valid-skill"
  printf '%s\n' keep >"$fixture/home/.claude/skills/alpha/marker"
  ln -s \
    "$fixture/outside/valid-skill" \
    "$fixture/home/.agents/skills/alpha"
  ln -s \
    "$fixture/outside/missing-skill" \
    "$fixture/home/.agents/skills/outside-dangling"
  ln -s \
    "$fixture/outside/valid-skill" \
    "$fixture/repo/skills/outside-redirect"
  ln -s \
    "$fixture/repo/skills/outside-redirect/missing-skill" \
    "$fixture/home/.agents/skills/repo-prefixed-but-outside"
  ln -s \
    "$fixture/outside/never-existed" \
    "$fixture/repo/skills/dangling-redirect"
  ln -s \
    "$fixture/repo/skills/dangling-redirect" \
    "$fixture/home/.agents/skills/repo-dangling-then-outside"

  if run_linker "$fixture"; then
    fail "linker succeeded despite conflicting unrelated skills"
  fi

  [ -f "$fixture/home/.claude/skills/alpha/marker" ] || \
    fail "conflicting real skill directory was removed"
  assert_link_to \
    "$fixture/home/.agents/skills/alpha" \
    "$fixture/outside/valid-skill"
  assert_link_to \
    "$fixture/home/.agents/skills/outside-dangling" \
    "$fixture/outside/missing-skill"
  assert_link_to \
    "$fixture/home/.agents/skills/repo-prefixed-but-outside" \
    "$fixture/repo/skills/outside-redirect/missing-skill"
  assert_link_to \
    "$fixture/home/.agents/skills/repo-dangling-then-outside" \
    "$fixture/repo/skills/dangling-redirect"
}

test_adds_new_skills
test_prunes_links_after_rename_or_removal
test_preserves_unrelated_skills

echo "link-skills tests passed"
