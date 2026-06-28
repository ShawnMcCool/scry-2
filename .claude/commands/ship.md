---
description: Commit and push changes — and optionally tag a release with a user-facing changelog and self-update safety check
allowed-tools: Bash, Read, Write, Edit
---

You are shipping changes for Scry2, and optionally tagging a release that the in-app self-updater (`Scry2.SelfUpdate`) will deliver to end users. Scry2's end users are Magic: The Gathering Arena players — not engineers. The release notes they read in **Settings → Updates → "What's new in vX.Y.Z"** and on the GitHub Releases page must be written for them.

> This skill supersedes the global `/ship` (`~/.claude/commands/ship.md`) when invoked from the Scry2 repo. Both share the same arg modes (`/ship` / `patch` / `minor` / `major`), the same halt-on-failure discipline, the same end-user changelog voice, and the same tag flow. This local version delegates the actual tagging mechanics to `scripts/tag-release` (which runs `mix precommit`, bumps `mix.exs`, rotates `## [Unreleased]`, commits the release, and pushes the tag) and adds Scry2-specific safety checks for the self-updater contract.

## Autonomy

**/ship is autonomous. Do not ask the user to confirm the commit message, the drafted changelog, the ship plan, or the tag step.** Draft, ship, tag — then report at the end. The only place to stop is a hard halt (safety-check failure, empty diff with no tag, unclear ambiguity that genuinely needs a human decision). When you stop, surface a tight report describing what's wrong and what's needed; do not put it behind an AskUserQuestion prompt. The user can re-run `/ship` once they've resolved the blocker, or amend `CHANGELOG.md` after the fact (the in-app disclosure reads from the file on disk; the GitHub release body is locked at tag time).

## Arguments

Invocation modes:

- `/ship` — plain ship. Commit working changes and push `main`. No tag.
- `/ship major` — ship AND bump **major** version (X.y.z → (X+1).0.0), draft user-facing changelog, run safety checks, tag, push.
- `/ship minor` — ship AND bump **minor** version (x.Y.z → x.(Y+1).0), same tag flow.
- `/ship patch` — ship AND bump **patch** version (x.y.Z → x.y.(Z+1)), same tag flow.

Anything else as an arg → invalid; stop with a clear message.

Scry2 is a single repo, so the multi-repo discovery logic from the global `/ship` is collapsed: this skill operates on the current working directory only, and that directory must be the Scry2 repo (contains `mix.exs` with `app: :scry_2`).

## Step 1: Sanity check

Verify CWD is the Scry2 repo:

```bash
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && grep -q 'app: :scry_2' mix.exs
```

If either check fails, stop with "Not in the Scry2 repo. /ship must be invoked from the project root."

## Step 2: Scan working state

Run `git status --short` and `git log -1`. Classify:

- **has changes** — `git status --porcelain` is non-empty (uncommitted work in the tree or index)
- **clean** — nothing to commit

If clean AND no version bump requested → tell the user "Nothing to ship" and stop.

## Step 3: Ship the working change

If the working copy has changes:

### 3a: Describe

- Run `git diff` to read the full diff
- Write a concise description: imperative verb phrase, sentence case, no trailing period, ≤ 72 chars on the subject line
- Use conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`
- If the diff contains multiple distinct types of work that cleanly partition by file, make separate commits (`git add <files> && git commit -m "<description>"` per group). If the work overlaps in shared files such that splitting would leave a broken intermediate state, ship as one combined commit and mention both topics in the description (e.g. `feat(web): nav refresh and per-set printing rollup`).

### 3b: Commit and push

```bash
git add -A
git commit -m "<message>"
git push origin main
```

If push fails, report the error and stop. If a tag is being requested, halt — don't tag a state that isn't on the remote.

## Step 4: Version bump + tag (only when mode is major|minor|patch)

### 4a: Self-update safety checks

**Before** drafting the changelog, validate the release will be safely consumable by the in-app updater. Scry2's self-update is described in `CLAUDE.md` and ADR-033. The contract surface is small but unforgiving: **a broken upgrade path on a live user's machine is the worst possible bug, because the path to recovery is "manually reinstall and lose `apply.lock` state."**

Compute the diff range:
```bash
last_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
range="${last_tag}..HEAD"
```

Run these checks. **Any failure is a hard halt** — print `UPGRADE SAFETY CHECK FAILED:` followed by a bulleted list explaining each failure, then stop. Do not offer a continue-anyway override; the user must fix the issue and re-run `/ship`.

1. **Tests pass.** Run `MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit` (zero-warnings policy + format + tests). `scripts/tag-release` runs this too, but failing here surfaces it before any drafting work. Any failure → halt.

2. **No unsafe migrations.** Run `mix ecto.migrations 2>&1 | grep -v ' up '`. Pending migrations themselves are fine (`Ecto.Migrator` runs them at startup), but the diff must not introduce a migration that drops a column or table containing user data — that violates `CLAUDE.md`'s **Data Integrity** rule. Inspect any new migration in `priv/repo/migrations/` and confirm it preserves data. Halt on any `drop` / `remove` of a column with rows.

3. **Self-updater contract intact.** The running tray binary on a user's machine reads `apply.lock` and subscribes to `updates:progress` PubSub. The state machine phase atoms are an external contract. Diff these files since `last_tag`:
   - `lib/scry_2/self_update/apply_lock.ex` — JSON schema (pid, version, phase, started_at). Adding fields is OK; renaming or removing fields breaks the tray watchdog reading older lock files written by the previous version.
   - `lib/scry_2/self_update/updater.ex` — phase atom names: `:idle | :preparing | :downloading | :extracting | :handing_off | :done | :failed`. Renaming any of these breaks any LiveView holding a stale subscription across the apply.
   - `lib/scry_2/self_update/checker_job.ex` — cron expression. Changing it is fine; mention in the changelog if the user-facing "next check" time would shift noticeably.
   - `installer/install.sh` — the curl-pipe bootstrap. Argv contract: `--version vX.Y.Z`. Don't break.
   - `rel/overlays/install.bat`, `rel/overlays/uninstall.bat` — Windows installer scripts. Self-update spawns these via `cmd /c`. Renaming files or breaking exit-code conventions strands users on the old version.
   - `installer/wix/` — MSI bootstrapper. Burn upgrade behavior depends on UpgradeCode stability. Don't change `UpgradeCode` GUID.

   Surface diffs in these files in the halt report if anything looks contract-breaking. If only formatting / comments / unrelated files change, pass.

4. **Settings.Entry compatibility.** Diff `lib/scry_2/settings/entry.ex` and any new migration touching `settings_entries`. Settings persisted under the `update.*` key namespace (e.g. `update.last_check_at`, `update.latest_known`) are read by the running release on startup. Renaming or dropping these keys breaks settings hydration — halt.

5. **IngestionState snapshot compatibility.** Diff `lib/scry_2/events/ingestion_state.ex` and the `ingestion_state` table migrations. The persisted snapshot uses an embedded schema that survives BEAM restarts. Adding fields is OK (defaults handle deserialization). Renaming or dropping fields breaks resume. Halt on any rename/drop.

6. **CHANGELOG present.** `CHANGELOG.md` exists with a `## [Unreleased]` header. The drafting step in 4b will populate it; this check just ensures the file structure is intact.

### 4b: Draft and prepend the user-facing changelog

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

5. Prepend the final notes to `CHANGELOG.md` **under `## [Unreleased]`** — leave `## [Unreleased]` as the header. `scripts/tag-release` will rotate that header to the versioned form when invoked in 4d. Do NOT write a `## v<version>` header yourself.

6. Commit the changelog edit on its own — `scripts/tag-release` requires a clean working tree:

   ```bash
   git commit -am "docs: changelog for v<version>"
   git push origin main
   ```

   The full changelog text goes in the summary at the end so the user can review what was drafted; no confirmation prompt.

### 4c: Tag and push

Invoke `scripts/tag-release <version>` directly — no confirmation:

```bash
scripts/tag-release X.Y.Z
```

The script:
- Runs `mix precommit` (test gate — already run in 4a, but the script re-runs it as belt-and-braces)
- Bumps version in `mix.exs`
- Rotates `## [Unreleased]` in CHANGELOG.md to `## vX.Y.Z — YYYY-MM-DD` with the body you wrote in 4b
- Commits the release as `chore: release vX.Y.Z`
- Tags `vX.Y.Z` on `main`
- Pushes `main` and the tag

The release workflow at `.github/workflows/release.yml` is triggered by the tag and builds Linux + macOS + Windows tarballs + MSI + per-platform `SHA256SUMS`. Kick off a background watch and report status in the final summary:

```bash
gh run watch "$(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
gh release view "v<version>" --json tagName,publishedAt,assets
```

If the test job fails with `DBConnection.ConnectionError: connection not available ... queue_timeout`, that's a known SQLite pool flake on the CI runner — re-run automatically with `gh run rerun <run_id> --failed`. For any other failure, report it without auto-rerunning.

Confirm the release published with all 7 assets (3 platform archives + 3 SHA256SUMS + 1 MSI).

## Step 5: Summary

Final report to the user:

- Working-copy change → description used → push result
- If tagged: target version, safety-check results, **the full changelog body that was prepended** (so the user can review and amend `CHANGELOG.md` if anything is off — the in-app disclosure reads from disk), tag push result, GitHub release URL.
- Reminder: the user's prod instance picks up the release via `Scry2.SelfUpdate.CheckerJob` (cron `"17 * * * *"`), so the in-app **Settings → Updates** card will show the new version within an hour.

## Important

- NEVER call `scripts/tag-release` directly outside this skill — it has no changelog-drafting step. (`tag-release` does have an empty-`[Unreleased]` guard as a backstop, but `/ship` is the path that produces good notes.)
- **Halt on safety-check failures.** Don't silently override and don't offer a continue-anyway prompt. The self-updater runs on the user's machine. A broken upgrade path means manual reinstall — and `apply.lock` may make even that messy. Report what's wrong; the user re-runs `/ship` after fixing.
- **End-user voice.** Changelog entries appear in **Settings → Updates → "What's new"**. If a line sounds like a commit message, rewrite it until it doesn't.
- **Drop noise.** Refactors, test-only changes, dependency bumps with no user impact, internal context reshuffles, ADR additions → omit. The git history carries the engineering trail; the changelog is for the player.
- **Be autonomous.** The user does not want to confirm the commit message, the changelog draft, or the tag step. Trust your judgment, ship, then report. The user can amend `CHANGELOG.md` post-tag if they want to refine the notes.
