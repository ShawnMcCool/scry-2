# Changelog

User-facing release notes for Scry2. Internal refactors, test changes,
and dependency bumps with no user impact are omitted here — see the git
history for the full engineering trail.

This file is the source of truth for the GitHub release body and the
in-app **What's new in vX.Y.Z** disclosure on Settings → Updates. Add
new entries under the Unreleased heading as you work; `scripts/tag-release`
renames that section on tag and the release workflow extracts it.

## [Unreleased]

## v0.32.2 — 2026-05-06

### Fixed

- **Card hover popups now point at the right card.** When a deck, draft pool, or match's revealed-cards section showed the same card multiple times (4× the same Island, a card that's both in the main deck and the sideboard, or a card added across two deck versions on the **Changes** tab), hovering over later copies would sometimes pop up the wrong card, and re-renders could swap cards into the wrong slot. Each copy now has a unique slot identity, so hovers and live updates target the correct one.

## v0.32.1 — 2026-05-05

### Fixed

- **Drafts page → Deck tab no longer crashes.** Opening any past draft and clicking the **Deck** sub-tab returned an Internal Server Error instead of showing the full draft pool grouped by card type. Creatures, Instants & Sorceries, Artifacts & Enchantments, and Lands now render correctly.

## v0.32.0 — 2026-05-03

### New

- **Economy → Mastery Pass card.** See your current Mastery Pass tier, XP toward the next tier, mastery orb count, season name, and how many days are left in the current season. The card refreshes whenever your collection does.

## v0.31.0 — 2026-05-03

### Improved

- **Memory reading uses less CPU during matches.** The reader now caches the most expensive parts of its setup work across polls, so every poll after the first costs a small fraction of what it did before. Long matches and Brawl/Commander games (which take longer per turn) feel notably lighter on the system.
- **Memory reading is harder to break by future MTGA updates.** Each memory-read pass now has a 500&nbsp;ms ceiling on top of the existing safety cap, so if a future MTGA build ever changes shape in a way that confuses the reader, the affected poll stops cleanly rather than hanging the app.

### New

- **Memory diagnostics page at Operations → Memory diagnostics →.** Inspect the live MTGA process, run a one-shot walker trace with read-count and timing, see what's in the discovery cache, and probe MTGA's class table by name. Useful when something looks off with rank, opponent name, or revealed cards and you want concrete numbers before reporting it.

## v0.30.3 — 2026-05-03

### Fixed

- **Memory reading is working again.** A read-count safety cap inside the memory reader was sized for an older MTGA build and was being silently exceeded on the current one — every match-start poll bailed before it could find the rank/board chain anchor, leaving opponent rank, screen name, and the Revealed cards section blank. The cap has been raised with several times the headroom over actual measured cost, and the memory reader is now also instrumented so future drift will surface before it breaks again.

### Improved

- The **Run diagnostic capture now** button on **Settings → Memory reading** now reports how many memory reads the walker used and what percentage of its budget that consumed — useful for spotting drift after a future MTGA update.

## v0.30.2 — 2026-05-03

### Improved

- **Settings → Memory reading** now exposes a "Verbose diagnostics" toggle and a "Run diagnostic capture now" button — useful when memory reading isn't producing data and you want a fast read on whether MTGA is reachable.
- Memory-reading log lines now appear under their own **:live_state** chip in the console drawer, separated from general ingestion noise.
- At every match wind-down, the console now records a one-line summary of what the memory reader saw — counts of successful, empty, and failed reads for both the rank chain and the board chain — making it easier to tell whether memory reading is working from one match to the next.

## v0.30.1 — 2026-05-03

### Maintenance

- Internal diagnostic logging for the Revealed cards capture path. No user-visible behavior change — adds a single log line at the end of every match summarizing whether memory-read board capture succeeded, so future investigation has direct evidence to work from.

## v0.30.0 — 2026-05-03

### Improved

- **More cards in the Revealed cards section.** The match detail page now shows cards from your opponent's **Hand** (revealed via Thoughtseize, Duress, etc.), **Graveyard**, and **Exile** in addition to the battlefield. Captured directly from MTGA's process memory at end-of-match, so you can finally see what your opponent was holding when they hit you with a discard spell. The Hand section is labelled **revealed only** to make clear it's just the cards that became visible during the match — not their full hand.

## v0.29.0 — 2026-05-03

### New

- **Opponent rank and screen name on the match detail page.** Scry now shows your opponent's rank (with mythic percentile / placement when applicable) and real MTGA screen name on the match detail page, captured at match start from MTGA's process memory — closing the gap where the log only ever told us the opponent's anonymized handle.
- **Revealed cards from MTGA's memory on the match detail page.** When a match ends, Scry now shows the cards that were visible on the battlefield at end-of-match — yours and your opponent's — under a new **Revealed cards** section on the match detail. Captured directly from MTGA's process memory while the game is live, then persisted at wind-down. Other zones (graveyard, exile, hand, stack, command) will follow.

### Improved

- **Consistent rank rendering everywhere.** Rank badges on the match detail, the matches list, and the live-match card now all share the same component, so a Mythic player at the same rank is displayed identically in every place it appears.

### Fixed

- **Mythic rank no longer shows a meaningless "1" tier.** MTGA always reports `tier=1` for Mythic players regardless of their actual standing, so previous releases would show "Mythic 1" instead of just "Mythic". The tier is now hidden when the rank is Mythic.

## v0.28.7 — 2026-05-02

### New

- **Pending Packs card on the Economy page.** Scry now shows your unopened booster inventory grouped by set — one row per set with the count, plus a total. Reads directly from MTGA's memory in every collection snapshot, so pack counts stay current as you crack and earn boosters.

### Improved

- **Trends strip on the Economy charts.** Above the Currency and Wildcards charts, a new strip shows your net gold and gem change over the selected time range (with a per-day rate) and an estimated **Vault opens …** date based on your recent rate of accumulating duplicate cards. The strip hides itself until enough snapshots exist to estimate.

## v0.28.6 — 2026-05-02

### Improved
- The **Recent Card Grants** card on the Economy page now shows which set you opened — e.g. "BLB pack opened" instead of "Pack opened" — so you can see the source of pack rewards at a glance.

## v0.28.5 — 2026-05-02

### New

- **Pack-opens are now labelled as "Pack opened" in Recent Card Grants.** When the cards Scry sees arrive in your collection coincide with one of your booster counts dropping, the grant row is now labelled **Pack opened** instead of the generic "Detected from collection" label. Memory-only grants that aren't pack-opens (or where the booster signal isn't present yet) keep the generic label. Scry now reads your unopened booster inventory directly from MTGA's memory in every collection snapshot.

## v0.28.4 — 2026-05-02

### New

- **Pack-opens and other unattributed cards now show up on the Economy page.** Recent Card Grants now also includes cards that arrived in your collection without a matching MTGA event-log row — most notably booster pack opens, but also any other grant the log doesn't (yet) carry. These rows are labelled **Detected from collection** so you can tell them apart from event prizes, vouchers, and draft pool grants. Detection runs whenever Scry takes a fresh memory snapshot of your collection.

## v0.28.3 — 2026-05-02

### New

- **Recent card grants on the Economy page.** Scry now shows the individual cards you got from event prizes, vouchers, and draft pool grants — pulled directly from MTGA's event log. Each row tells you where the card came from (e.g. "Event prize", "Draft pool grant", "Voucher") and which cards landed in your collection. Duplicates that converted to vault progress are marked with **(vault)**. Pack-opens will appear here automatically the first time you crack a booster after this update.

## v0.28.2 — 2026-05-02

### New

- **Heads-up when MTGA gets updated.** Scry's memory reader is tied to MTGA's process layout, which can shift when MTGA patches. **Settings → Memory Reading** now shows a one-click "MTGA was updated — acknowledge" warning the next time your collection is read after a new MTGA build, so you know to open MTGA and refresh to confirm cards are still being read correctly. Click **Acknowledge** once everything looks right and the alert stays quiet until the next update.

## v0.28.1 — 2026-05-02

### New

- **An "Active match" card on the Matches page now shows your opponent live during a match.** While a match is in flight, the **Matches** dashboard surfaces both players' screen names, ranks, current game number, and (in Brawl) commander identities — pulled from MTGA's memory and refreshing every half-second. The card disappears as soon as the match ends. Live polling can still be turned off in **Settings → Memory Reading**.

## v0.28.0 — 2026-05-02

### New

- **See which cards you crafted on the Economy page.** A new **Recent Crafts** card lists every wildcard spend with the card you made — image, name, rarity, and when. Tracking starts the first time Scry reads your collection from memory; older crafts can't be recovered, since MTGA stopped writing them to its log in 2021.

## v0.27.3 — 2026-05-01

### Fixed

- **Stopped Scry from pinning a CPU core after MTGA quits mid-match.** If you quit MTGA while a match was still in flight, Scry could get stuck inside its memory-reader and keep one CPU core busy until you manually restarted the app. Polling now stops cleanly when the read fails, and the memory reader has a hard ceiling on how much work a single read can do — so any future failure mode terminates promptly instead of looping.

## v0.27.2 — 2026-05-01

### Maintenance

- Internal fix for a development-mode routing crash on URLs containing colon characters. Does not affect the installed production app.

- Removed an unused database table (`cards_cards_archive`) that held a one-time forensic snapshot from the April 2026 card-data migration. Your installed app will run a small cleanup migration on first launch — no user-visible behavior change.

## v0.27.1 — 2026-04-30

### Fixed

- **Reduced background log churn during gameplay.** Scry was writing every database query to its log file at full verbosity in production, producing several megabytes of log data per minute while you played. Logs now only record warnings and errors, so the `~/.local/share/scry_2/log/` directory fills up much more slowly and disk activity is lower.

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
