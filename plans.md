# scry_2 — roadmap

A living tracker of capabilities not yet built. Items are removed as they
ship; the CHANGELOG and git history hold what was done. Each item is
tagged with its prerequisite:

- **today** — buildable now with existing snapshot data
- **live** — needs per-tick broadcast from `Scry2.LiveState` (only the
  final match snapshot is persisted today)
- **reader+** — needs a new walker traversal in
  `native/scry2_collection_reader/` (one ADR per new memory structure)
- **storage** — needs the raw-event store to shrink first
  (`docs/storage-split-campaign.md`)

This is a brainstorm tracker, not a commitment. Order is not priority.

**Canonical references for walker / `reader+` work:**

- `decisions/architecture/2026-04-22-034-memory-read-collection.md` —
  the ADR; **Revision 2026-04-25** contains the walker-in-Rust rationale
  and the NIF contract.
- `.claude/skills/mono-memory-reader/SKILL.md` — every walker offset, the
  verification recipe (via `offsets_probe/`), and live-disassembly
  evidence.
- `native/scry2_collection_reader/src/bin/class_fields_probe.rs` — dumps
  a class's field manifest by name, or walks Chain 2 to real battlefield
  cards; use it to confirm runtime class/field names before coding.

## Active campaigns

- `docs/storage-split-campaign.md` — shrink the raw event store, then
  split into capture client + UI server. Server tier scaffolding exists
  (`Scry2.ServerRepo`, `docker-compose.yml`).
- `docs/find-more-netdeck-sources-campaign.md` — additional netdeck
  sources under the same conservative bar (no challenge-solving, honor
  robots.txt).
- `docs/dual-name-cards-campaign.md` — Universes Within / Universes
  Beyond name aliases so netdecks resolve both names.

## A. Snapshot extensions (one-shot reads)

- Constructed / Limited / Historic rank + tier + percentile — **reader+**
- Daily / weekly quest contents and progress — **reader+**
- Win-track (15-win) progress and claimed rewards — **reader+**
- Event entry fees for events not yet joined (`EventInfoV3.EntryFees` via
  the EventManager chain) — **reader+**
- Store inventory (daily deal, rotating bundles, cosmetic packs) — **reader+**
- Pending packs by set and source — **reader+**
- Server environment + build version + host platform as walker fields
  (`PAPA._instance.<FdConnectionManager>._currentEnvironment →
  EnvironmentDescription`; confirmed in spike 23, not yet wired) — **reader+**
- Asset catalog version (`<AssetLookupSystem>` resolves to a loader, not a
  manifest; needs a separate catalog object) — **reader+**
- Vanity selections (avatar / cardBack / pet / title) — walker already
  reads the slot strings; no UI yet — **today**

## B. Reconciliation (memory-vs-log truth diffing)

- Booster-count reconciliation (memory pack inventory vs log pack events) — **reader+**
- Deck-list reconciliation (memory deck vs log-submitted deck) — **reader+**
- "Verify everything" admin button (runs every reconciliation) — composes the above

## C. Pre/post-match capture

- Pre-match deck snapshot when log fires `MatchCreated` — **reader+**
- Pre-match opponent snapshot from lobby memory — **reader+**
- Companion legality verification — **reader+**

## D. Live tracking (continuous reads)

- Per-tick board history (only the final snapshot is persisted) — **live**
- Active match HUD feed (life, hand, library, gy, exile, mana, stack) — **live** + **reader+**
- Real-time draft pack reader (cards seen but passed) — **live** + **reader+**
- Real-time mana / card-advantage tracker — **live** + **reader+**
- Opponent disconnect / concede early-detection — **live** + **reader+**
- Active-screen detection (lobby / deckbuilder / match / store) — **live** + **reader+**
- Backfill: historical `live_match_revealed_cards` rows with `arena_id=0`
  (pre-2026-07-21 reveal-filter bug) and battlefield rows at `seat_id=0`
  (pre-2026-07-22 ownership bug) were left as-is; a rebuild is only
  possible from new captures — **today**, low value

## E. Forecasting (snapshot-stream analytics)

- Vault opening ETA from vault-progress slope — **today**
- Currency burn-rate dashboard (gold/gems/wildcards over time) — **today**
- Quest-reroll EV calculator — **reader+**
- Win-track velocity / weekly reward attainment — **reader+**

## F. Alerting / guardrails

- Rank-decay countdown around month rollover — **reader+**
- Cosmetic-on-sale-you-don't-own alert — **reader+**
- Quest-about-to-expire alert — **reader+**

## G. Brewing / deck library

- Deck library mirror (every saved deck in MTGA) — **reader+**
- Deck history / auto-backup on every change — **reader+** + **live**
- Sideboard awareness per deck — **reader+**
- Brew-in-progress capture for real-time companion UI — **reader+** + **live**

## H. Game replay from the log

`GreToClientEvent` carries every `GameStateMessage` (zones, objects,
counters, annotations) and `ClientToGreMessage` carries every player
action (`PerformActionResp`, `SubmitAttackersReq`, `SelectTargetsResp`,
`DeclareBlockersResp`, `AssignDamageResp`, `CastingTimeOptionsResp`).
Together they reconstruct every turn: draws, casts, attacks, blocks, life
changes, zone transitions.

Domain events to design (discrete facts, no pre-aggregation):
`TurnCompleted`, `SpellCast`, `CombatResolved`, `ZoneTransition`.

Enables: replay timeline, per-turn draw/play sequence, combat analytics,
mana-efficiency tracking. Prerequisites: extend `match_context` to hold
full zone state across `GameStateMessage`s, handle
`diffDeletedInstanceIds`, detect turn boundaries, parse annotations for
triggers / combat / resolution. Significant work — **storage** first.

## UI

- Deck rendering engine (UIDR-012): per-page `ViewSpec` controls
  (grouping, text/images, splay depth) persisted via `Settings.Entry`.
- Netdeck variant matrix (UIDR-014): contested nonland cards × cluster
  members on `/netdecks/:id`, `+N`/`−N` cells vs the viewed deck, frozen
  name pane, `Manabase ±N` / `Sideboard ±N` / `Total Δ` footer. Supersedes
  the UIDR-013 per-row delta lines (never built).
- Decks-page card search — adopt DeckList facets + the shared search_box
  component (already shipped for netdecks, ADR-045).

## I. Composed capabilities

- Personal draft database (every pack seen, every card passed) — **D** + **storage**
- Account-wide value tracker (collection value over time) — **today**
- Real-time match exporter (OBS overlay, Discord bot, Twitch ext.) — **D**
