# Changelog

User-facing release notes for Scry2. Internal refactors, test changes,
and dependency bumps with no user impact are omitted here — see the git
history for the full engineering trail.

This file is the source of truth for the GitHub release body and the
in-app **What's new in vX.Y.Z** disclosure on Settings → Updates. Add
new entries under the Unreleased heading as you work; `scripts/tag-release`
renames that section on tag and the release workflow extracts it.

## [Unreleased]

### Fixed

- **Cards with a Scryfall flavor-name treatment now use the canonical
  art on the per-set Collection page.** Some printings have two
  Scryfall rows at the same set/collector number — a regular row plus
  a parody / anime / Universes Beyond "flavor name" overlay (e.g.
  *The Very Hungry Archaic* over *Wildgrowth Archaic* in SOS). The
  image lookup wasn't ordering its results, so SQLite could pick the
  overlay's anime-style art for the card tile. Scry2 now consistently
  prefers the canonical printing, the same way card-name selection has
  worked since v0.46.3. No reimport needed — the change takes effect
  on the next page load.

## v0.46.5 — 2026-05-16

### Improved

- **Pages now respond faster on first load.** The **Insights**,
  **Cards**, **Collection**, **System**, **Matches**, **Match Economy**,
  **Operations**, and individual insight pages were running database
  queries during the initial HTTP render, which made them feel slow to
  appear. Scry2 now defers that work until the page connects over
  WebSocket, so the first paint comes back immediately and the data
  fills in as it's ready.

## v0.46.4 — 2026-05-16

### Improved

- **Every page now shows a "catching up" banner when the event
  pipeline is still absorbing work in the background.** Just after a
  self-update — or after you trigger **Operations → Reingest** — Scry2
  spends a minute or two replaying your MTGA event log into its
  internal projections. Previously the dashboard came back up looking
  ready while it was still finalising things, so the Drafts page (or
  any other page driven by those projections) could briefly show
  partial numbers. A soft banner at the top of the page now indicates
  when the pipeline is more than ~50 events behind, with a live count
  that updates every few seconds and disappears once everything is
  caught up.

## v0.46.3 — 2026-05-16

### Fixed

- **Cards with a Scryfall flavor-name treatment now display their
  real Oracle name on the Collection page.** Some Magic printings
  carry a cosmetic "flavor name" overlay — for example, the SOS
  printing of *Wildgrowth Archaic* also exists as a parody-art row
  named `"The Very Hungry Archaic"` in Scryfall's bulk data. The
  card synthesis step was picking the flavor-name row over the
  canonical one in a tie, so the regular printing showed up under
  the parody name (and your owned copies looked like they belonged
  to a card you didn't have). Synthesis now skips flavor-name rows
  whenever a canonical row exists at the same set + collector
  number. After the update the affected cards will resolve to the
  correct name on the next card refresh.

## v0.46.2 — 2026-05-16

### Fixed

- **Follow-up to v0.46.1.** The previous patch added the read-time
  draft-record computation but missed where MTGA actually emits the
  identifier that ties a submitted deck to its draft — so after
  updating to v0.46.1 and running a reingest, Premier and Pick Two
  drafts could still show `0–0`. Scry2 now reads that identifier
  from the right MTGA payload, so a reingest from **Operations →
  Reingest** stamps every draft with its deck-submission time and
  the per-format records appear correctly.

## v0.46.1 — 2026-05-16

### Fixed

- **Premier Draft and Pick Two Draft records now display correctly
  on the Drafts page.** Previously every Premier or Pick Two run
  showed `0–0`, even after you'd played multiple matches with the
  drafted deck, and the **By Format** breakdown showed `—` for
  those formats. Quick Draft was largely unaffected. The fix
  rebuilds how match results are attached to a draft so the
  per-format win rates, average wins, and trophy counts reflect
  your actual play history across all three draft formats.

## v0.46.0 — 2026-05-16

### Improved

- **Your collection now refreshes automatically every 15 minutes**
  while MTGA is running. Previously the refresh only fired when
  you completed a match or made a draft pick, so if you opened
  packs from the store without playing, your **Collection** page
  could show outdated counts. Now the snapshot stays current
  regardless of in-game activity. You can still click **Refresh
  now** for an immediate update.

## v0.45.0 — 2026-05-16

### Improved

- **The navigation moved to a collapsible left rail.** Cards
  lives at the top; your match, deck, draft, profile, economy,
  and collection pages are grouped below it. Click the toggle
  button to collapse the rail to a narrow icon strip when you
  want more screen space for the page content — your preference
  is remembered.
- **The per-set Collection page now rolls up alternate art
  printings.** Owning 2 regular + 2 alternate art of "Emeritus
  of Truce" now counts as a complete playset of 4 instead of
  showing as two separate partial cards. The Missing / Partial /
  Complete counts, the per-rarity playset totals, and the gap
  sections all count by card name, not by printing — so the
  numbers reflect what you can actually build with.

## v0.44.0 — 2026-05-16

### New

- **Collection → set drill-in.** Click any set tile on the **Collection**
  page to open a focused per-set view that shows three counts at a
  glance — cards you don't own at all, cards you have a partial playset
  of, and cards you've completed at four copies — plus a per-rarity
  breakdown and the actual cards you still need to chase. Each card
  shows a 4-pip indicator for how many copies you currently own.

### Improved

- The **Collection** overview is cleaner: only your six newest sets are
  shown up front (with a "+N older sets not shown" hint), the general
  composition chart is gone, and recent acquisitions now sit directly
  below the set tiles.
- The **Cards** page auto-focuses the search field on load, so you can
  start typing immediately.

### Fixed

- The **Vault** percentage on the **Collection** page now displays
  correctly. Previously it was double-multiplied and could show values
  over 6000%.

## v0.43.0 — 2026-05-13

### Improved

- **Decks page** loads and renders faster. The deck grid now does a single
  image-cache lookup per render instead of one per card, and filtering by
  "only played" skips loading deck contents you'd just discard.
- **Home page** opens instantly with placeholder tiles, then fills in
  once the daily insights are ready — no more blank screen on first
  load.
- **Matches page** loads quicker. The overall stats, format breakdown,
  rolling win-rate, and recent matches panels now load in parallel
  instead of one after another.
- **Live MTGA capture** is smoother during bursts of activity. The
  watcher releases the database write lock sooner, so the dashboard
  stays responsive while MTGA is generating a wave of events.
- **Daily insight refresh** is faster — independent pattern detectors
  now run in parallel.

## v0.42.0 — 2026-05-13

### New

- **Homepage redesign.** The dashboard at `/` is now a 4-tile exhibit
  showing patterns the app noticed in your play — your strongest
  format, decks running hot, mulligan tax, and more. Every measurement
  shows its sample size so you know how much to trust it.
- **Insights page.** Browse every active pattern at `/insights`, or
  click any homepage tile to open its explainer at `/insights/:id`
  (measurements, confidence, when it was computed).
- **Thirteen pattern detectors** run daily on your play data:
  - **On play vs on draw** — your win rate split by who goes first
  - **Mulligan tax** — how much mulligans cost you
  - **BO1 vs BO3 split** — the gap between the two formats
  - **Best format** — your strongest queue
  - **Deck on a heater** — when a deck is winning well above your baseline
  - **Color combo** — when a mana combo performs far from your baseline
  - **Draft signal** — whether your first-pick rarity tracks draft wins
  - **Rank milestone** — when you crossed into Silver/Gold/Platinum/Diamond/Mythic
  - **Draft conversion** — average wins per draft and trophy count over your last 10 runs
  - **Play schedule** — whether you're a weekend warrior or a weeknight grinder
  - **BO3 resilience** — how often you come back from losing game 1
  - **This week's crafting** — wildcards you've spent in the last 7 days
  - **This week's economy** — your gem/event balance over the last 30 days

### Improved

- **Detail pages redesigned.** Match, deck, draft, ranks, economy, and
  player pages now share the homepage's visual language — small
  uppercase kickers above each section, Beleren titles, sample-size
  cues throughout.
- **System health moved.** The previous home page (server health,
  updates card) now lives at **Settings → System** in the gear menu.

### Fixed

- **Player and Matches pages no longer crash on real data.** A
  pre-existing bug in the cumulative-win-rate query crashed when
  matches had no start timestamp; the matches detail page had a
  related crash sorting opponent history. Both fixed.

## v0.41.3 — 2026-05-09

### Improved

- **The dashboard stays responsive while MTGA emits events.** The
  System (health) card no longer re-runs its full snapshot on every
  ingested event — it now coalesces bursts into one refresh, so the
  dashboard doesn't slow down during long play sessions with heavy
  activity.
- **Faster deck history as it grows.** Added covering database
  indexes for the Decks → Matches tab and the per-deck win-rate
  charts. The pages already feel instant today; this keeps them that
  way as your match history accumulates.
- **Lighter ingestion footprint.** Several internal write paths
  during MTGA log processing have been batched and de-duplicated,
  reducing the SQLite write rate during steady play. No change in
  what gets recorded — just less churn getting it there.

## v0.41.2 — 2026-05-08

### Fixed

- **Set completion percentages on the Collection page were
  wildly inflated for new sets.** Secrets of Strixhaven and Teenage
  Mutant Ninja Turtles showed completions like 2125% and 1930% — the
  expected card count was being computed from a tiny set of mis-tagged
  rows instead of the real per-rarity totals. Both numerator and
  denominator now line up with the actual cards available in the set.
  This fix runs automatically as a post-update task on first boot
  after the update.

### Improved

- **Rarity bars on each set tile are sorted most-rare to least-rare.**
  Mythic sits on the left, then rare, uncommon, common, so the cards
  that actually drive completion progress catch your eye first.

## v0.41.1 — 2026-05-08

### New

- **Post-update tasks now run automatically.** When an app update
  introduces work that needs to happen once on your existing data —
  for example, re-running card synthesis after the join-key change in
  v0.40.0 — it now runs automatically on the first boot after the
  update. You no longer have to wait for the daily refresh window or
  hunt for a manual button.
- **Settings → Operations → Post-update tasks.** A new card on the
  Operations page lists every post-update task: what it does, whether
  it has been applied, and when. If a task fails, you can re-run it
  from here without restarting the app.

### Improved

- **Cards from Secrets of Strixhaven, Teenage Mutant Ninja Turtles,
  and Avatar: The Last Airbender now show full data on existing
  installs.** v0.40.0 introduced the join-key change that fixes these
  sets, but on an already-running install nothing triggered a fresh
  synthesis until the next daily refresh. The new post-update tasks
  framework re-runs synthesis automatically, so the fix lands
  immediately after this update applies.

## v0.40.0 — 2026-05-08

### Fixed

- **The Collection page now shows your newest sets correctly.** Sets
  released before Scryfall finishes tagging Arena IDs — for example
  Secrets of Strixhaven, Teenage Mutant Ninja Turtles, and Avatar: The
  Last Airbender — were appearing as bare three-letter codes (`SOS`,
  `TMT`, `TLA`) with no release date, sorted to the bottom of the grid.
  They now show their proper printed names and release dates and sort
  correctly with the rest of your collection.
- **Cards from those new sets now show full card data.** Type lines,
  rarity, and other detail were previously stripped down to basic
  MTGA-only metadata for any card that Scryfall hadn't yet tagged with
  an Arena ID. Over a thousand cards across the three sets above are
  now fully recognized.

## v0.39.1 — 2026-05-08

### Fixed

- **Linux: self-updates that ran after the v0.37.x systemd-rename
  series finished cleanly halfway through.** The installer crashed on
  `loginctl enable-linger "$USER"` because the in-app updater spawns
  the installer with a stripped environment and `$USER` was not in the
  whitelist. The result was a partially-installed release: files
  copied, unit installed, but the service never started by the
  installer (only by systemd's auto-restart). Both the script's
  fallback (`${USER:-$(id -un)}`) and the updater's env whitelist now
  cover this.

## v0.39.0 — 2026-05-08

### Improved

- **The settings gear no longer disappears at narrow window widths.** The
  header now reserves space for the gear and the player picker on the
  right edge so they're always visible — no more hunting for them when
  the window is shared with another app.
- **The settings gear is now a dropdown.** Click it to jump straight to
  System, Operations, Settings, or Console without first landing on the
  System page and clicking through tabs. When an update is waiting, a
  small `vX.Y.Z` chip appears next to the cog and inside the dropdown
  so you can spot it from any page.
- **Top-nav links collapse to a hamburger menu on narrower windows.** At
  half-screen widths the 9 main nav items fold into a single menu so the
  header no longer overflows.

## v0.38.0 — 2026-05-08

### Improved

- **Collection page now shows real set names and expansion symbols.** The
  per-set tiles on the Collection page used to show just a 3-letter code
  (`FIN`, `TDM`, `FDN`); they now show the proper name (*Final Fantasy*,
  *Tarkir: Dragonstorm*, *Foundations*) alongside the familiar Magic
  expansion symbol. The active-set breadcrumb above your card grid uses
  the same treatment.
- **Sets are sorted by release date, most recent first.** Newer sets
  appear at the top of the Collection grid, so the set you're actively
  drafting or building decks for is right where you'd look. Sets with
  no Scryfall release date (a few archival codes) sort to the bottom.
- **Set names and release dates flow in from Scryfall on the next refresh.**
  After this update, the next time Scry refreshes its card data (hourly,
  or via **Settings → Card data → Refresh now**), every Arena set gets
  populated with its proper name and date.

## v0.37.3 — 2026-05-08

### Fixed

- **Linux: self-updates no longer get cut short halfway through.**
  The installer that runs during a self-update lived inside the same
  systemd cgroup as the running Scry service. The moment the service
  stopped (which the installer itself triggers, by design), the
  installer was killed along with it — leaving the new version
  half-installed and the unit unstarted. The installer now relocates
  itself out of the parent cgroup before doing any work, so it runs
  to completion regardless of what happens to the old service.

## v0.37.2 — 2026-05-08

### Fixed

- **Linux: stopping the systemd unit no longer leaves it in `failed` state.**
  The `bin/scry_2 stop` helper completed its job (the running BEAM drained gracefully)
  but the helper's own cleanup crashed on Elixir 1.19.5, exiting non-zero and pushing
  systemd to mark the unit as failed. A failed unit refuses to auto-start at boot —
  which is why the service didn't come back up after a system restart. The unit now
  ignores the helper's exit code; graceful shutdown is unchanged.

## v0.37.1 — 2026-05-08

### Improved

- **Linux: the systemd unit is now `scry-2.service`** (with a dash, matching the dev unit).
  `systemctl --user start scry-2` is now the supported control surface — old
  `scry_2.service` (underscore) installs are migrated automatically: the old unit is
  stopped, disabled, and removed before the new one is installed and started. Your
  database, config, and snapshots are untouched.

## v0.37.0 — 2026-05-08

### New

- **The Collection page is rebuilt with much more detail.** You can now see your collection broken down several ways:
  - **Composition** — your owned cards by rarity, colour, and type.
  - **Completion** — per-set rarity ratios, so you can see how close you are to completing each set.
  - **Craft plan** — incomplete playsets paired with your wildcard counts, so you know what's worth crafting next.
  - **Holding browser** — browse your owned cards directly, with filtering and grouping.
  - **Recent acquisitions** — what's been added to your collection lately.
  - **Wildcard summary** — wildcard counts at a glance.
- **Build-change banner.** When MTGA installs a new build, the banner that already showed on Settings now also appears on the Collection page so you know when card data is refreshing.

## v0.36.1 — 2026-05-08

### Fixed

- **Catching up after a long offline window no longer crashes Scry.**
  When Scry started up against a large backlog of unread MTGA events
  (after an extended pause, an MTGA update, or a system reboot), the
  initial bulk insert tried to stuff every event into a single SQL
  statement and tripped SQLite's hard 32,766-placeholder ceiling. The
  insert is now chunked, so any backlog size catches up cleanly.

## v0.36.0 — 2026-05-08

### Improved

- **Linux: Scry now runs as a proper systemd user service.** The system
  tray icon is gone on Linux; the backend is managed by
  `systemctl --user start/stop/status scry_2` instead, and a
  **Scry2** entry shows up in your application launcher that opens
  the dashboard in your default browser. Auto-start on login and
  crash-restart are handled by systemd, the same way every other
  long-running personal service on your machine works. Existing
  installs are migrated automatically on the next update — the old
  tray and its autostart entry are removed and replaced with the
  systemd unit. Your database, config, and snapshots are untouched.
  Windows and macOS continue to use the tray.

## v0.35.0 — 2026-05-07

### Improved

- **Memory reading is faster on subsequent polls.** When the cards
  in your collection haven't changed since the last memory snapshot,
  the reader now skips re-walking the cards table and reuses the
  prior list. Currencies, mastery, cosmetics, and the rest of the
  inventory still update every poll — the optimisation only skips
  the part that hasn't moved. Frees up budget for future per-snapshot
  data without raising the cost ceiling.

### New

- **MTGA environment line on Settings.** A small line under the
  memory-reading toggle now shows the server you're connected to
  (Prod, etc.), the MTGA build version, and the host platform
  (Steam). Useful for confirming you're on the build a friend just
  patched to, or for filing bug reports with the exact build you
  were running.

## v0.34.2 — 2026-05-07

### Fixed

- **Restore the v0.34.1 release.** v0.34.1 was tagged but never reached
  the in-app updater because the release build broke during the
  preceding dependency refresh. v0.34.2 is the same maintenance update
  with the build issue fixed.

## v0.34.1 — 2026-05-07

### Maintenance

- **Internal dependency refresh.** Updated Phoenix, Bandit, Oban,
  Ecto, Jason, the Rust NIF crates, and the Go tray modules to their
  latest compatible versions. No behavior changes — this is a routine
  maintenance pass to keep the upstream libraries current.

## v0.34.0 — 2026-05-07

### New

- **Mastery Pass forecast.** The Mastery Pass card on the Economy page
  now shows your current XP-per-day pace and the tier you're projected
  to reach by season end. Hidden until there's enough history to
  estimate, and skips itself if your XP hasn't moved.
- **Low wildcard warning.** Wildcard counts on the Economy page now
  turn amber when a rarity drops at or below a sensible floor — common
  50, uncommon 30, rare 15, mythic 5 — so a near-empty rarity catches
  your eye before you craft into it.
- **MTGA discriminator in the player switcher.** The player picker in
  the top bar now shows your full MTGA screen name with the
  `#NNNNN` discriminator (e.g. *Shawn McCool#91813*) when Scry has
  read it from MTGA's memory. Falls back to the bare name from the
  log when memory hasn't been read yet.
- **Cosmetics inventory on the Economy page.** A new card shows your
  per-category cosmetic counts — Alt arts, Avatars, Pets, Sleeves,
  Emotes — alongside the master totals from MTGA, with a small
  progress bar per category. Hidden until Scry's memory reader has
  captured a snapshot. Categories MTGA hasn't loaded yet (Titles, in
  particular, only loads after you visit the Cosmetics screen) are
  hidden rather than shown as 0 / 0.

### Fixed

- **Memory reader now populates currencies, vault, and build version.**
  A subtle bug in how Scry walked MTGA's internal card-collection table
  caused the memory reader to silently fall back to its slower
  best-effort scan on every snapshot — leaving wildcards, gold, gems,
  vault progress, and the MTGA build version blank on the Economy
  page. With the table now read correctly, those values populate as
  soon as MTGA is running.

## v0.33.0 — 2026-05-06

### New

- **Active events on the Economy page.** A new card under the
  Mastery Pass shows every event you're actively engaged with —
  Premier Drafts in progress, Quick Drafts, Jump-In runs, plus your
  standing on the always-on ladders (Standard, Traditional Standard,
  Historic, etc.) — each with its current win–loss record. Reads
  live from MTGA, so the numbers match what the game shows.

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
