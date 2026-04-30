# Changelog

User-facing release notes for Scry2. Internal refactors, test changes,
and dependency bumps with no user impact are omitted here — see the git
history for the full engineering trail.

This file is the source of truth for the GitHub release body and the
in-app **What's new in vX.Y.Z** disclosure on Settings → Updates. Add
new entries under the Unreleased heading as you work; `scripts/tag-release`
renames that section on tag and the release workflow extracts it.

## [Unreleased]

## v0.27.0 — 2026-04-30

### New

- **Match economy capture.** Scry now records the gold,
  gems, wildcards, and vault progress that change across each
  match. The match detail page shows what you earned (or lost),
  and the **Matches** dashboard shows a running ticker of recent
  earnings.

- **New Match economy page.** The nav link **Match economy**
  opens a sortable, date-filtered timeline of every match's
  currency delta — quick way to see how a session, a draft, or a
  whole week shook out.

- **Reconciliation status per match.** Each match's economy entry
  shows whether the memory reading and MTGA's log events agreed,
  whether one source was missing, or whether the data is
  incomplete — so you can spot when MTGA dropped a log event.

- **Live opponent info during a match.** While a match is
  running, Scry now reads the opponent's rank and screen name
  (and your commander, in Brawl) directly from MTGA's memory.
  New toggles in **Settings → Memory Reading** and the first-run
  setup tour let you turn live polling and economy capture off.

### Improved

- **Smoother economy charts.** The currency-over-time chart on
  the **Economy** page skips data points where nothing changed,
  giving you cleaner step lines and faster page loads.

## v0.26.0 — 2026-04-30

### Improved

- **Card data is now built from your MTGA install + Scryfall.**
  Names, rarities, types, and oracle text come straight from the game's
  local card database and Scryfall's bulk data — no longer relying on
  17lands' CSV. Scry sees exactly what's in your Arena, including
  alt-art printings, and refreshes automatically when MTGA pushes a new
  set.

- **Alt-art printings now merge into one card entry.** Showcase,
  borderless, anime, and other unique art treatments of the same card
  collapse into a single entry on the **Cards** and **Decks** pages,
  instead of cluttering the list as separate rows.

- **The MTGA card database imports automatically.** New sets are picked
  up shortly after MTGA pushes a content patch, so newly opened cards
  show up without you having to trigger a refresh.

- **Win-rate charts now use a rolling window for smoother trend
  lines.** New period toggles let you switch between weekly, monthly,
  and longer windows to see how your performance evolves over
  different time scales.

## v0.25.11 — 2026-04-29

### New

- **The Matches page filter is now organized by category.** A new
  top row groups your formats into **Limited**, **Constructed**, and
  **Other** with match counts on each. Clicking a category narrows the
  per-format chips below it, so you can drill from "all my Limited" to
  a specific event without scanning a long flat row. The BO1/BO3 and
  Wins/Losses toggles still work in combination, and the URL
  round-trips so reloads keep your filter.

### Fixed

- **Pick Two Draft matches are now labeled correctly.** Previously
  they appeared as **PickTwoDraft** under **Other** in the matches
  filter; they now show as **Pick Two Draft** under **Limited**
  alongside Premier Draft, Quick Draft, and Sealed. New Pick Two
  matches will be correct automatically. To relabel matches you've
  already played, run **Settings → Operations → Reingest** on this
  version.

## v0.25.10 — 2026-04-29

### Fixed

- **Draft win/loss records are no longer aggregated across multiple
  drafts of the same format and set.** Premier Draft showed records
  like *9–6* (impossible — max is 7 wins) and Pick Two Draft showed
  *3–8* (impossible — max is 2 losses). MTGA assigns the same
  internal event name to every Premier (or Pick Two) draft you run
  in a given set/date window, so the previous reconciliation summed
  matches across every draft of that format and stamped the same
  number onto each row. Each draft now only counts the matches that
  happened inside its own time window — between its start and the
  start of the next draft of the same format. Quick Draft was
  always correct because each Quick Draft already had a unique
  event name. Rebuild the **Drafts** projection (Settings →
  Operations) on this version to refresh existing rows.

## v0.25.9 — 2026-04-29

### Fixed

- **Reingest no longer crashes the app under real-history load.** When
  you ran **Settings → Operations → Reingest** against a full match
  history, the rebuild fan-out — every projector running concurrently,
  every match upsert triggering a draft recount, every draft update
  triggering its own broadcast cascade — saturated the database pool
  and brought down the whole runtime. The pipeline now rebuilds
  projectors one at a time and skips the cross-projector
  notification storm during a rebuild; after each rebuild a single
  reconciliation pass writes the derived numbers (most visibly,
  draft win/loss records). Reingest should now complete cleanly on
  any history size.

- **Pick Two and Premier draft win/loss records recover on rebuild.**
  Rebuilding the **Drafts** projection (Settings → Operations) now
  always writes the correct W–L on every draft from your match
  history in one batch step, instead of relying on a per-match
  cascade that could be interrupted by a crash and leave the page
  stuck at 0–0.

## v0.25.8 — 2026-04-29

### Improved

- **The crash log now captures *why* the app went down, not just *that*
  it did.** v0.25.7 wrote a log file that was usually empty for the
  last few seconds before a hard restart, because the underlying log
  rotator buffered writes and the OTP runtime's own crash reports
  were filtered out by default. Both gaps are closed: the file
  handler now flushes to disk every second, and supervisor crash
  reports flow into the same `<data dir>/log/scry_2.log` file so the
  evidence trail survives the next BEAM exit.

- **The app tolerates transient hiccups under heavy operations.**
  Operations like **Reingest** can briefly stress SQLite hard enough
  that a worker process bounces — entirely normal under load, not a
  real failure. Previously, three such bounces in five seconds would
  bring the whole app down. The threshold is now ten in thirty
  seconds, so background-ops blips no longer kill the BEAM, while a
  genuine failure still aborts cleanly.

## v0.25.7 — 2026-04-29

### Improved

- **Logs now persist across restarts.** Scry2 writes its log to
  `<data dir>/log/scry_2.log` (5 rotating files, ~25MB total). If the
  app ever crashes, the events leading up to it are still on disk
  instead of being wiped with the in-memory Console drawer. On Linux
  that's `~/.local/share/scry_2/log/`, on Windows `%APPDATA%\scry_2\log\`,
  on macOS `~/Library/Application Support/scry_2/log/`.

- **The Operations page now shows the previous BEAM crash, if any.**
  When the app's underlying runtime dies hard (rather than a graceful
  shutdown), Erlang writes a crash dump. **Settings → Operations** now
  shows a yellow "Last BEAM crash" card with the timestamp, the
  slogan, and the path to the preserved dump file — so you don't have
  to dig through the filesystem to find out what happened. Up to 5
  recent crash dumps are retained.

## v0.25.6 — 2026-04-28

### Fixed

- **Rebuilds no longer silently drop matches from your draft records.**
  When you ran **Settings → Operations → Rebuild** on the Matches
  projection, transient errors on individual events were being swallowed
  silently — the rebuild would report "complete" while quietly skipping
  rows. The most visible fallout: Pick Two and Premier draft records
  could show **0–0** even when matches were played. Rebuild now logs an
  error in the Console drawer (press `` ` ``) listing how many events
  were skipped and a sample of their ids, so you know whether to re-run
  the rebuild or investigate. **If your draft records are stuck at 0–0,
  open Settings → Operations and rebuild the Matches projection again
  on this version to recover them.**

## v0.25.5 — 2026-04-28

### Fixed

- **Reingest no longer crashes the app.** Running **Settings → Operations →
  Reingest** could disconnect the dashboard and shut the app down before
  finishing — leaving historical matches missing from your match list. The
  background work that rebuilds your match history now keeps going past
  individual problem events instead of bringing the whole process down.

## v0.25.4 — 2026-04-28

## v0.25.3 — 2026-04-26

### Fixed

- **In-app updates no longer leave the app dead.** Applying an update
  through **Settings → Updates** ran the new release's installer
  cleanly, but the relaunched tray crashed with *"Gtk-WARNING: cannot
  open display:"* and the BEAM never came back. The self-updater's
  `env -i` isolation was scrubbing `DISPLAY` / `WAYLAND_DISPLAY` /
  `XAUTHORITY` along with the stale `RELEASE_*` vars. The whitelist
  now passes those GUI session vars through; the installer also
  rehydrates them from systemd as a fallback for upgrades from older
  versions still using the buggy whitelist.

## v0.25.2 — 2026-04-26

### Fixed

- **Operations page no longer crashes.** Opening **Settings → Operations**
  in the production app returned an Internal Server Error because the
  service-detection helper read the build environment via a runtime
  call to `Mix`, which is not loaded in installed releases. The
  environment is now captured at compile time, so the page loads
  cleanly under the tray supervisor.

## v0.25.1 — 2026-04-26

### Fixed

- **Auto-update no longer leaves the app stopped.** After applying an
  update, the running release's environment was leaking into the new
  installer — pointing the freshly relaunched tray at a release
  directory that had just been deleted. The backend would die in its
  startup wrapper, and the watchdog would respawn zombie after zombie
  while the UI stayed unreachable until you restarted it manually.
  The installer now runs with a clean environment, so the new release
  starts cleanly the moment the apply finishes.

## v0.25.0 — 2026-04-25

### New

- **See what's new before you update.** Settings → Updates now has a
  *What's new in vX.Y.Z* disclosure under the **Apply update** button.
  Expand it to read the curated release notes for the version you're
  about to install — headings, bullets, bold, inline code, the lot —
  without round-tripping to GitHub. The notes render in a contained,
  scrollable panel so longer changelogs stay tidy.

## v0.24.2 — 2026-04-25

Maintenance release — no user-visible changes. Internal cleanup of the
collection-diagnostics LiveView (logic extracted to a helper module per
ADR-013) and a Rust type-alias to silence a clippy warning in the
collection reader NIF.
