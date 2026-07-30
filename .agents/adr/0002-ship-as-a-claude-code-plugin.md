# Ship the skill set as a native Claude Code plugin; defer a native Codex plugin

These skills have always been installable via [skills.sh](https://skills.sh/mattpocock/skills) (`npx skills add mattpocock/skills`), which copies editable skill files into a user's project across Claude Code, Codex, and other Agent-Skills-standard harnesses. A recurring request is a **plug-and-play** distribution: subscribe to the set as a read-only, always-current bundle you don't edit, rather than a fork you own. That is exactly what native plugin systems provide.

We ship a native **Claude Code plugin** and, for now, **defer** a native **Codex plugin**. The split is forced by how each ecosystem's plugin manifest selects skills, against this repo's bucketed layout.

## The constraint: bucketed skills vs. single-path selection

Skills live in bucket folders under `skills/` — `engineering/` and `productivity/` are **promoted** (shipped); `misc/`, `personal/`, `in-progress/`, and `deprecated/` are **not**. A plugin must expose only the promoted set, which spans two of those bucket folders.

- **Claude Code** — `.claude-plugin/plugin.json` accepts `skills` as an **array of explicit skill-directory paths**. We list the promoted skills one by one, exclude everything else with zero ambiguity, and add `.claude-plugin/marketplace.json` so the repo is its own single-plugin marketplace. Verified end to end: `claude plugin validate . --strict` passes, and `marketplace add` → `install` resolves all promoted skills.

- **Codex** — `.codex-plugin/plugin.json` accepts `skills` only as a **single path string** (arrays are rejected with `missing or invalid plugin.json`), and Codex discovers `SKILL.md` files recursively under it. There is no way to name two bucket folders, or to curate a subset, from one path. Two escape hatches were tested and rejected:
  - Pointing at `./skills/` would also ship `deprecated/`, `in-progress/`, `personal/`, and `misc/` — retired, draft, and personal skills we deliberately don't promote.
  - A curated flat directory of **symlinks** into the buckets does not survive install: Codex copies the plugin tree into its cache and **drops symlinks**, so the skills arrive empty.

The only robust ways to give Codex a single promoted-only path are (a) **restructure** so `skills/` contains only promoted skills (moving the non-promoted buckets out — a large blast radius across `CLAUDE.md`, `scripts/link-skills.sh`, the bucket READMEs, and the local dev workflow that relies on `in-progress/` and `personal/`), or (b) **commit duplicate copies** of promoted skills into a flat directory (a sync burden and a second source of truth). Both are structural decisions, not something to bundle into shipping the Claude plugin. This is very likely the original, half-remembered reason a plugin wasn't shipped earlier: the manifest formats didn't cleanly express a curated subset of a bucketed repo.

## Decision

- Ship the **Claude Code plugin** now (`.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json`), curated to the promoted set, as the headline v1.2 deliverable.
- Keep **skills.sh** as the universal installer — it already serves Codex and other harnesses today, so no Codex user is left without an install path.
- **Defer** the native Codex plugin until we decide between restructuring `skills/` to promoted-only vs. committing a generated flat copy. Revisit when Codex either supports a `skills` array / include-list or preserves symlinks on install.

## Invariants this creates

- Every promoted skill has an entry in `.claude-plugin/plugin.json`'s `skills` array (this already stood as a `CLAUDE.md` rule; it now also gates the plugin's contents).
- `.claude-plugin/plugin.json`'s `version` tracks `package.json`'s version — bump both together on release. Claude uses the plugin `version` to decide when installed users see an update.

## Amended 2026-07-30 — the blocking constraint is refuted; the deferral survives on new grounds

**The decision above still stands: ship the Claude plugin, defer the Codex one. Its reasoning does not.** Everything above this line is left intact as written; this section names what no longer holds.

**What changed.** `.codex-plugin/plugin.json` now accepts `skills` as an array of path strings ([openai/codex#28790](https://github.com/openai/codex/pull/28790), merged 2026-06-18), and manifest-declared roots **replace** the default `./skills` root rather than supplementing it. So `["./skills/engineering", "./skills/productivity"]` would ship exactly the promoted set and never reach `misc/`, `personal/`, `in-progress/`, or `deprecated/`.

Basis, stated precisely because the sources disagree: this is read from the **shipped loader**. OpenAI's published plugin docs still document `skills` as a single string, and #28790's own description claims declared roots load *alongside* the default root — which the loader contradicts. Where they conflict the loader governs, and anyone acting on this should re-read it rather than trust this paragraph: the surface is moving weekly.

**Why the deferral survives anyway.** Not for the reason given above. The manifest change removes the *capability* blocker; what remains is need. **Operator ruling, 2026-07-30** (recorded on [#8](https://github.com/jdpretzel/project-home/issues/8) in the same change-set as this amendment): no Codex plugin is built or shipped — this fork serves one operator, who reproduces the environment by cloning the repo rather than installing it, so there are no installers to serve.

The trigger is therefore need-shaped, replacing the capability-shaped one below: **build the Codex plugin when the operator's own work requires it.** What that would take has not been measured and should not be assumed small — the array route is untested here, and no `.codex-plugin/` manifest has been written.

### Statements above that no longer hold

| The claim | Status |
|---|---|
| These skills "have always been installable via skills.sh (`npx skills add mattpocock/skills`)" | **Retired for this fork.** [#8](https://github.com/jdpretzel/project-home/issues/8) dropped `npx skills add`: the CLI's tree scan surfaces all 41 skills, not the promoted 23. The command also points readers at *upstream's* copy — the defect class [#19](https://github.com/jdpretzel/project-home/issues/19) exists to fix. |
| "The split is **forced** by how each ecosystem's plugin manifest selects skills" | **Retired.** Nothing is forced. The split is a choice, and it is now made on need. |
| The section heading "The constraint: bucketed skills vs. single-path selection" | **Retired as a constraint.** Single-path selection is no longer how Codex reads a manifest. |
| "Verified end to end: `claude plugin validate . --strict` passes" | **Retired.** [#14](https://github.com/jdpretzel/project-home/issues/14) made the plugin version-less, so `--strict` now fails permanently by design. The check is `claude plugin validate .` without `--strict`, per `CLAUDE.md`. |
| "`skills` only as a **single path string** (arrays are rejected …)" | **Retired.** Arrays are accepted; see above. |
| "There is no way to name two bucket folders, or to curate a subset, from one path" | **Retired.** Two bucket roots do exactly that. |
| Codex "copies the plugin tree into its cache and **drops symlinks**" | **Still true — but no longer load-bearing.** [openai/codex#24770](https://github.com/openai/codex/issues/24770) is open and an approved fix was auto-closed unmerged. This was one of two blockers; the other is gone, and the array route makes symlinks irrelevant to packaging. Recorded so nobody reaches for the flat-symlink escape hatch and rediscovers the wall. |
| "The **only** robust ways … are (a) **restructure** … or (b) **commit duplicate copies**" | **Retired as a dilemma.** The manifest array is a third way, needing neither. |
| Shipping the Claude plugin "as the headline **v1.2** deliverable" | **Retired.** #14 made the plugin version-less; cutting a release *is* merging to `main`. |
| "Keep **skills.sh** as the universal installer — … no Codex user is left without an install path" | **Retired.** With `npx skills add` dropped, Codex users have no install path from this fork. Accepted knowingly under the ruling above. |
| "**Defer** … **until we decide between** restructuring `skills/` … vs. committing a generated flat copy" | **Retired.** That choice is abolished along with the dilemma. The deferral waits on need, not on a structural decision. |
| "Revisit when Codex either supports a `skills` array / include-list **or** preserves symlinks on install" | **Discharged.** The array limb has fired and this section is the revisit. The symlink limb has not fired. |
| "`.claude-plugin/plugin.json`'s `version` tracks `package.json`'s version — bump both together" | **Retired.** #14 deleted `package.json` and dropped the `version` field; `CLAUDE.md` forbids re-adding one. |

### What is unchanged

The Claude Code plugin half, the bucketed-layout description, and the first invariant — every promoted skill has an entry in `plugin.json`'s `skills` array — all stand.
