# scry_2 — capability roadmap from MTGA memory reading

A living tracker of capabilities unlocked by reading MTGA's process memory,
beyond what `Scry2.Collection` already does (cards dictionary snapshot via
the structural scanner). Each item is tagged with its prerequisite:

- **today** — buildable now with the existing scanner output
- **walker** — gated on walker phase 6 (wildcards, gold, gems, vault, build hint)
- **live** — gated on a new continuous-poll subsystem (no GenServer yet)
- **reader+** — gated on extending the memory reader to a new structure

This is a brainstorm tracker, not a commitment. Order is not priority.

## Walker phase 6 — shipped

The Rust walker (`native/scry2_collection_reader/`, ADR-034 Revision
2026-04-25) is complete: NIF wired, Elixir integration in
`Scry2.Collection.Reader` (walker-first with scanner fallback),
`SelfCheck.walker_result_ok?/2` validating output, `Snapshot` schema
populated end-to-end (cards + wildcards + gold/gems/vault_progress +
build hint), and the `walker share %` KPI rendered on the Collection
diagnostics page. 178 Rust unit tests pass, `cargo clippy --all-targets`
is clean.

**Canonical references for follow-on walker / `reader+` work:**

- `decisions/architecture/2026-04-22-034-memory-read-collection.md` —
  the ADR; **Revision 2026-04-25** at the bottom contains the
  walker-in-Rust rationale and the NIF contract.
- `.claude/skills/mono-memory-reader/SKILL.md` — canonical reference
  for all walker offsets, the verification recipe (via
  `offsets_probe/`), and live-disassembly evidence. Two independent
  sources per offset: (1) Unity mono `unity-2022.3-mbe` headers +
  the C dumper, (2) live disassembly of MTGA's `mono-2.0-bdwgc.dll`.
- `mtga-duress/research/002-mtga-memory-reader-design.md` — evidence
  summary across all spikes.
- `mtga-duress/experiments/spikes/spike{5,6,7}/FINDING.md` —
  field-resolution algorithm, prologue-byte pattern for
  `mono_get_root_domain`, and the PAPA→inventory pointer chain.

## A. Snapshot extensions (one-shot reads, same model as today)

- Account identity (username, player UUID, account-creation timestamp) — **reader+**
- Constructed / Limited / Historic rank + tier + percentile — **reader+**
- Mastery pass tier, XP, free-vs-premium, mastery orbs — **reader+**
- Daily / weekly quest contents and progress — **reader+**
- Win-track (15-win) progress and claimed rewards — **reader+**
- Cosmetics inventory (pets, sleeves, avatars, alt arts, emotes) — **reader+**
- Event entry tokens (sealed, draft, premier-play) — **reader+**
- Active event records (e.g. 4-1 in a Premier Draft) — **reader+**
- Store inventory (daily deal, rotating bundles, cosmetic packs) — **reader+**
- Pending packs by set and source — **reader+**
- Build / version metadata (build GUID, asset version, server region) — **walker**
- Booster inventory (per-set unopened pack counts) — **✅ shipped** (`Scry2.Collection.Snapshot.boosters_json`; walker reads `ClientPlayerInventory.boosters: List<ClientBoosterInfo>` per spike 18)

## B. Reconciliation (memory-vs-log truth diffing)

- Currency reconciliation (memory wildcards/gold/gems vs log `InventoryUpdated`) — **✅ shipped** (per-match, see C below)
- Booster-count reconciliation (memory pack inventory vs log pack events) — **walker** + **reader+**
- Log-gap detector (currency change observed in memory but no matching log event) — **✅ shipped** (per-match `reconciliation_state`)
- Deck-list reconciliation (memory deck vs log-submitted deck) — **reader+**
- "Verify everything" admin button (runs every reconciliation) — composes above

## C. Pre/post-match capture (one-shot reads at known transitions)

- Pre-match deck snapshot when log fires `MatchCreated` — **reader+**
- Pre-match opponent snapshot from lobby memory — **reader+**
- Post-match economy delta (memory snapshot before/after match) — **✅ shipped** (`Scry2.MatchEconomy`, ADR-036)
- Per-match economy timeline + dashboard ticker + match-detail card — **✅ shipped** (`/match-economy`)
- Pack-open card capture via memory snapshot diff — **✅ shipped** (`Scry2.Economy.AttributeMemoryGrants` + `IngestMemoryGrants`; surfaces as `source: "MemoryDiff:PackOpen"` rows in Recent Card Grants when a booster count dropped in the diff window, otherwise `source: "MemoryDiff"`)
- Companion legality verification — **reader+**

## D. Live tracking (continuous reads — new architectural mode)

`Scry2.LiveState` plumbing **shipped (Chain 1)**: GenServer polls 500 ms
on `MatchCreated → MatchCompleted`, persists `live_state_snapshots`,
broadcasts `live_match:updates` / `live_match:final`. Settings toggle
+ setup-tour step ship the kill switch. The walker NIF currently
returns the rank/screen-name/commander chain only — every "Chain 2"
item below (board state) is still gated on `walker/card_holder.rs`
(blocked on parent-class + GRE captures, see task #22).

- LiveView UI consuming `live_match:updates` (rank/screen-name/commander) — **✅ shipped** (`Scry2Web.Components.LiveMatchCard` on `/matches`)
- Active match HUD feed (life, hand, library, gy, exile, mana, stack) — **live** + **reader+**
- Real-time draft pack reader (cards seen but passed) — **live** + **reader+**
- Real-time mana / card-advantage tracker — **live** + **reader+**
- Opponent disconnect / concede early-detection — **live** + **reader+**
- Active-screen detection (lobby / deckbuilder / match / store) — **live** + **reader+**

## E. Forecasting (snapshot-stream analytics)

All gated on walker phase 6 producing a stream of currency/progression rows.

- Vault opening ETA from vault-progress slope — **walker**
- Mastery pass completion ETA vs season end — **walker**
- Currency burn-rate dashboard (gold/gems/wildcards over time) — **walker**
- Quest-reroll EV calculator — **walker** + **reader+**
- Win-track velocity / weekly reward attainment — **walker** + **reader+**

## F. Alerting / pre-action guardrails

- Wildcard floor alarm before a craft drops below threshold — **walker**
- Rank-decay countdown around month rollover — **reader+**
- MTGA build-change alert (revalidate parser/walker) — **walker**
- Cosmetic-on-sale-you-don't-own alert — **reader+**
- Quest-about-to-expire alert — **reader+**

## G. Brewing / deck library

- Deck library mirror (every saved deck in MTGA) — **reader+**
- Deck history / auto-backup on every change — **reader+** + **live**
- Sideboard awareness per deck — **reader+**
- Brew-in-progress capture for real-time companion UI — **reader+** + **live**

## H. Composed capabilities

- Personal draft database (every pack seen, every card passed) — **D + storage**
- Account-wide value tracker (collection value over time) — **walker** + **today**
- Real-time match exporter (OBS overlay, Discord bot, Twitch ext.) — **D**

## Cross-cutting prerequisites

- **Walker phase 6 — ✅ shipped.** Wildcards, gold, gems, vault progress,
  and build hint are now read end-to-end by the Rust walker and persisted
  on every `Scry2.Collection` snapshot. See "Walker phase 6 — shipped" at
  the top of this file for refs. B/E/F items can now be picked up on top
  of real walker data.
- **Live-state GenServer — ✅ shipped (Chain 1).** `Scry2.LiveState.Server`
  polls every 500 ms while a match is active, gated by the
  `live_match_polling_enabled` Settings flag (on by default, configurable
  in setup tour and Settings → Memory Reading). Chain 1 reads
  rank/screen-name/commander via `MtgaMemory.walk_match_info/1`. Chain 2
  (board state) is still gated on `walker/card_holder.rs` — see task #22.
- **Reader extensions** (`reader+`) — each new memory structure (rank object,
  deck list, quest list, etc.) needs its own walker-style traversal. Current
  scanner only finds the cards dictionary. Each extension is its own ADR.
