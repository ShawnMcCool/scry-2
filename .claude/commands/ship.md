---
description: Describe, bookmark, push jj changes — and optionally tag a release with a user-facing changelog and self-update safety check
allowed-tools: Bash, AskUserQuestion, Read, Write, Edit
---

You are shipping one or more Jujutsu (jj) changes for Scry2, and optionally tagging a release that the in-app self-updater (`Scry2.SelfUpdate`) will deliver to end users. Scry2's end users are Magic: The Gathering Arena players — not engineers. The release notes they read in **Settings → Updates → "What's new in vX.Y.Z"** and on the GitHub Releases page must be written for them.

> This skill supersedes the global `/ship` (`~/.claude/commands/ship.md`) when invoked from the Scry2 repo. Both share the same arg modes (`/ship` / `patch` / `minor` / `major`), the same halt-on-failure discipline, the same end-user changelog voice, and the same tag flow. This local version delegates the actual tagging mechanics to `scripts/tag-release` (which runs `mix precommit`, bumps `mix.exs`, rotates `## [Unreleased]`, describes the jj change, and pushes the tag) and adds Scry2-specific safety checks for the self-updater contract.

## Arguments

Invocation modes:

- `/ship` — plain ship. Describe working change(s), advance, bookmark, push `main`. No tag.
- `/ship major` — ship AND bump **major** version (X.y.z → (X+1).0.0), draft user-facing changelog, run safety checks, tag, push.
- `/ship minor` — ship AND bump **minor** version (x.Y.z → x.(Y+1).0), same tag flow.
- `/ship patch` — ship AND bump **patch** version (x.y.Z → x.y.(Z+1)), same tag flow.

Anything else as an arg → invalid; stop with a clear message.

Scry2 is a single repo, so the multi-repo discovery logic from the global `/ship` is collapsed: this skill operates on the current working directory only, and that directory must be the Scry2 repo (contains `mix.exs` with `app: :scry_2`).

## Step 1: Sanity check

Verify CWD is the Scry2 repo:

```bash
test -d .jj && grep -q 'app: :scry_2' mix.exs
```

If either check fails, stop with "Not in the Scry2 repo. /ship must be invoked from the project root."

## Step 2: Scan working state

Run `jj diff --stat` and `jj log --limit 1`. Classify:

- **has changes** — diff is non-empty OR the working change already has a description (not "(no description set)")
- **clean** — empty diff AND "(no description set)"

If clean AND no version bump requested → tell the user "Nothing to ship" and stop.

## Step 3: Plan and confirm

Show the engineer:

- Current working-copy state (file count, change description if any)
- Whether shipping with or without tagging
- If tagging: current version (from `mix.exs`), target version after bump, the bump type

Use `AskUserQuestion` to get explicit confirmation before any mutation. If the user declines, stop.

## Step 4: Ship the working change

Only after confirmation. If the working copy has changes:

### 4a: Describe

- Run `jj diff` to read the full diff
- Write a concise description: imperative verb phrase, sentence case, no trailing period, ≤ 72 chars on the subject line
- Use conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`
- If the change already has a description that matches the diff, keep it
- If the diff contains multiple distinct types of work, split with `jj split -m "<description>" <files>` (the `-m` flag avoids opening an editor)

### 4b: Advance, bookmark, push

```bash
jj desc -m "<message>"
jj new
jj bookmark set main -r @-
jj git push --bookmark main
```

If push fails, report the error. If a tag is being requested, halt — don't tag a state that isn't on the remote.

## Step 5: Version bump + tag (only when mode is major|minor|patch)

### 5a: Self-update safety checks

**Before** drafting the changelog, validate the release will be safely consumable by the in-app updater. Scry2's self-update is described in `CLAUDE.md` and ADR-033. The contract surface is small but unforgiving: **a broken upgrade path on a live user's machine is the worst possible bug, because the path to recovery is "manually reinstall and lose `apply.lock` state."**

Compute the diff range:
```bash
last_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
range="${last_tag}..HEAD"
```

Run these checks. If any fail, halt with `UPGRADE SAFETY CHECK FAILED:` followed by a bulleted list. Use `AskUserQuestion` to ask whether to abort or continue anyway — override is explicit, never silent.

1. **Tests pass.** Run `MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit` (zero-warnings policy + format + tests). `scripts/tag-release` runs this too, but failing here surfaces it before any drafting work. Any failure → halt.

2. **No unsafe migrations.** Run `mix ecto.migrations 2>&1 | grep -v ' up '`. Pending migrations themselves are fine (`Ecto.Migrator` runs them at startup), but the diff must not introduce a migration that drops a column or table containing user data — that violates `CLAUDE.md`'s **Data Integrity** rule. Inspect any new migration in `priv/repo/migrations/` and confirm it preserves data. Halt on any `drop` / `remove` of a column with rows.

3. **Self-updater contract intact.** The running tray binary on a user's machine reads `apply.lock` and subscribes to `updates:progress` PubSub. The state machine phase atoms are an external contract. Diff these files since `last_tag`:
   - `lib/scry_2/self_update/apply_lock.ex` — JSON schema (pid, version, phase, started_at). Adding fields is OK; renaming or removing fields breaks the tray watchdog reading older lock files written by the previous version.
   - `lib/scry_2/self_update/updater.ex` — phase atom names: `:idle | :preparing | :downloading | :extracting | :handing_off | :done | :failed`. Renaming any of these breaks any LiveView holding a stale subscription across the apply.
   - `lib/scry_2/self_update/checker_job.ex` — cron expression. Changing it is fine; mention in the changelog if the user-facing "next check" time would shift noticeably.
   - `installer/install.sh` — the curl-pipe bootstrap. Argv contract: `--version vX.Y.Z`. Don't break.
   - `rel/overlays/install.bat`, `rel/overlays/uninstall.bat` — Windows installer scripts. Self-update spawns these via `cmd /c`. Renaming files or breaking exit-code conventions strands users on the old version.
   - `installer/wix/` — MSI bootstrapper. Burn upgrade behavior depends on UpgradeCode stability. Don't change `UpgradeCode` GUID.

   Surface diffs in these files to the engineer; halt if anything looks contract-breaking. If only formatting / comments / unrelated files change, pass.

4. **Settings.Entry compatibility.** Diff `lib/scry_2/settings/entry.ex` and any new migration touching `settings_entries`. Settings persisted under the `update.*` key namespace (e.g. `update.last_check_at`, `update.latest_known`) are read by the running release on startup. Renaming or dropping these keys breaks settings hydration — halt.

5. **IngestionState snapshot compatibility.** Diff `lib/scry_2/events/ingestion_state.ex` and the `ingestion_state` table migrations. The persisted snapshot uses an embedded schema that survives BEAM restarts. Adding fields is OK (defaults handle deserialization). Renaming or dropping fields breaks resume. Halt on any rename/drop.

6. **CHANGELOG present.** `CHANGELOG.md` exists with a `## [Unreleased]` header. The drafting step in 5b will populate it; this check just ensures the file structure is intact.

### 5b: Draft a user-facing changelog

Scry2's audience is the MTGA player using the dashboard. They care about: drafts/matches/cards showing up, cards being correctly recognized, the dashboard loading, updates not breaking the app, the tray icon working. They do not care about: bounded contexts, projections, anti-corruption layers, GenServers, ADRs, content hashes, projector watermarks.

1. Collect commits since the previous tag:
   ```bash
   git log --pretty=format:"- %s" "${last_tag}..HEAD"
   ```

2. Rewrite each commit in end-user language. Translate jargon. Examples:

   | Commit subject | User-facing rewrite |
   |---|---|
   | `fix(events): broaden EventPlayerDraftMakePick ack-shape matcher` | Fixed an issue where some draft picks weren't being recorded after MTGA changed the format of its acknowledgment messages. |
   | `fix(events): translate new MTGA human draft wire format (CourseId-keyed)` | Fixed Premier and Pick Two drafts not appearing on the Drafts page. |
   | `feat(updates): show 'What's new in vX.Y.Z' inline before applying update` | You can now read the release notes for a new version directly from **Settings → Updates** before applying it. |
   | `fix(self_update): pass GUI session env (DISPLAY/WAYLAND_DISPLAY/XAUTHORITY) through to the installer` | Fixed an issue where applying an update would leave the app stopped on Linux desktops. |
   | `fix(service): bake mix env at compile time so prod releases don't crash on /operations` | Fixed the **Settings → Operations** page returning an Internal Server Error in production. |
   | `refactor(events): extract IdentifyDomainEvents.MatchRoom helper` | (drop — internal refactor, no user impact) |
   | `chore: bump phoenix to 1.7.21` | (drop — dependency bump, no user impact) |
   | `test(parser): add fixture for new MTGA event type` | (drop — test-only change) |

3. Group entries:
   - **New** — user-visible features that didn't exist before
   - **Improved** — UX, performance, dashboard polish, additional data the user can now see
   - **Fixed** — bugs the user could observe (data not appearing, crashes, broken pages, broken updates)

   Skip empty sections. A patch with only fixes doesn't need a "New" heading.

4. **Voice rules.** Present tense, active, second person where natural ("You can now…", "The Drafts page now…", "Fixed an issue where…"). Bold the key term in each entry where it helps scanning (`**Settings → Updates**`, `**Drafts page**`). No emoji, no marketing language ("blazing fast", "completely revamped"), no internal vocabulary leaking out.

5. Present the draft to the engineer via `AskUserQuestion` with two options: "Use as-is" or "Edit before tagging".
   - If "Edit": write the draft to `/tmp/scry2-release-notes-<version>.md`, tell the engineer to edit it, ask for confirmation when done, then read the edited file back in.

6. Prepend the final notes to `CHANGELOG.md` **under `## [Unreleased]`** — leave `## [Unreleased]` as the header. `scripts/tag-release` will rotate that header to the versioned form when invoked in 5d.

   Do NOT write a `## v<version>` header here — `scripts/tag-release` does that. Just populate the body of `[Unreleased]`.

### 5c: Confirm before tagging

Show the engineer the populated `## [Unreleased]` section in CHANGELOG.md and the target version. Use `AskUserQuestion` with options "Tag and push" / "Cancel".

If cancelled, stop. The CHANGELOG edit stays in the working copy as a normal jj change — the engineer can describe and ship it later, or revert it.

### 5d: Tag and push

Invoke `scripts/tag-release <version>`:

```bash
scripts/tag-release X.Y.Z
```

The script:
- Runs `mix precommit` (test gate — already run in 5a, but the script re-runs it as belt-and-braces)
- Bumps version in `mix.exs`
- Rotates `## [Unreleased]` in CHANGELOG.md to `## vX.Y.Z — YYYY-MM-DD` with the body you wrote in 5b
- Describes the jj change as `chore: release vX.Y.Z`
- Tags `vX.Y.Z` and moves the `main` bookmark
- Pushes both the bookmark and the tag

The release workflow at `.github/workflows/release.yml` is triggered by the tag and builds Linux + macOS + Windows tarballs + MSI + per-platform `SHA256SUMS`. Wait for it:

```bash
gh run watch "$(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
gh release view "v<version>" --json tagName,publishedAt,assets
```

Confirm the release published with all 7 assets (3 platform archives + 3 SHA256SUMS + 1 MSI).

## Step 6: Summary

Final report to the engineer:

- Working-copy change → description used → push result
- If tagged: target version, safety-check results, changelog preview path, tag push result, GitHub release URL
- Reminder: the user's prod instance picks up the release via `Scry2.SelfUpdate.CheckerJob` (cron `"17 * * * *"`), so the in-app **Settings → Updates** card will show the new version within an hour.

## Important

- NEVER use `jj commit` — jj's working copy is already a commit
- NEVER mutate anything before the engineer confirms in Step 3 (and again in 5c)
- NEVER call `scripts/tag-release` directly outside this skill — it has no changelog-drafting step. (`tag-release` does have an empty-`[Unreleased]` guard as a backstop, but `/ship` is the path that produces good notes.)
- **Halt on safety-check failures.** Don't silently override. The self-updater runs on the user's machine. A broken upgrade path means manual reinstall — and `apply.lock` may make even that messy.
- **End-user voice.** Changelog entries appear in **Settings → Updates → "What's new"**. If a line sounds like a commit message, rewrite it until it doesn't.
- **Drop noise.** Refactors, test-only changes, dependency bumps with no user impact, internal context reshuffles, ADR additions → omit. The git history carries the engineering trail; the changelog is for the player.
