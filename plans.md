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

- Account identity — **mostly shipped.** `Scry2.Players` captures `screen_name` + `mtga_user_id` from `LoginV3` log events; the walker (`walker/account.rs`, spike 22) reads MTGA's `DisplayName` (with discriminator, e.g. `"Shawn McCool#91813"`) and `ExternalID` from `PAPA._instance.<AccountClient>.<AccountInformation>` and stamps `mtga_display_name` onto the matching `Player`. The layout's player switcher renders the discriminator-bearing form when present. **Account-creation timestamp is genuinely unavailable** — `AccountInformation` does not expose it client-side; would require a server query (out of scope for memory reading).
- Constructed / Limited / Historic rank + tier + percentile — **reader+**
- Mastery pass tier, XP, mastery orbs, season name, season end — **✅ shipped** (`Scry2Web.Components.MasteryCard` on `/economy`; walker reads `PAPA._instance → MasteryPassProvider → AwsSetMasteryStrategy → ProgressionTrack` per spike 20). Free-vs-premium intentionally dropped — not surfaced in MTGA's mastery-pass memory state for this season.
- Daily / weekly quest contents and progress — **reader+**
- Win-track (15-win) progress and claimed rewards — **reader+**
- Cosmetics inventory (pets, sleeves, avatars, alt arts, emotes) — **✅ shipped.** `Scry2.Collection`'s walker reads `_availableCosmetics` and `_playerOwnedCosmetics` `CosmeticsClient` instances and stamps per-category counts on each snapshot via `cosmetics_json`. Rendered as a Cosmetics card on `/economy` — categories with `available > 0` show owned / total + a per-row progress bar (Alt arts, Avatars, Pets, Sleeves, Emotes). The Titles category is hidden until MTGA hydrates `_titlesCatalog` (lazy-loaded on first UI access — see spike22 FINDING). The walker also reads the `ClientVanitySelectionsV3` slot strings (avatar / cardBack / pet / title) for future surface; not yet displayed.
- Event entry tokens (sealed, draft, premier-play) — **partially shipped** (per-entry `entry_fee` + `entry_currency_type` already captured from `EventJoined` domain events for events the player has joined; the Event History table on `/economy` shows them). The remaining **reader+** piece is reading `EventInfoV3.EntryFees` from the EventManager chain to preview costs for available-but-not-yet-joined events.
- Active event records (e.g. 4-1 in a Premier Draft) — **✅ shipped v0.33.0** (`Scry2Web.Components.ActiveEventsCard` on `/economy`; walker reads `PAPA._instance → EventManager → EventContexts → ClientPlayerCourseV3` per spike 21. Anchor unlocks event entry tokens / win-track / quests as follow-ons.)
- Store inventory (daily deal, rotating bundles, cosmetic packs) — **reader+**
- Pending packs by set and source — **reader+**
- Build / version metadata — **partially shipped** (walker stamps `mtga_build_hint` on every snapshot; `Scry2.Collection.BuildChange` raises a banner on `/settings` when the hint changes between snapshots). **Server environment + build version + host platform** are now pinned to a single chain (`PAPA._instance.<FdConnectionManager>._currentEnvironment → EnvironmentDescription`, see spike 23 FINDING). One field reads the human-readable environment label (`"Prod"`); another (`fdHost`) embeds the MTGA build version in the front-door hostname. `<AssetLookupSystem>` resolves to a loader, not a manifest — asset version still **walker** (separate catalog object, follow-on spike). Wiring spike 23 into a real walker chain is the **reader+** piece.
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
- Pack-open card capture via memory snapshot diff — **✅ shipped** (`Scry2.Economy.AttributeMemoryGrants` + `IngestMemoryGrants`; surfaces as `source: "MemoryDiff:PackOpen"` rows in Recent Card Grants when a booster count dropped in the diff window, otherwise `source: "MemoryDiff"`. Set code resolved via `Scry2.Cards.BoosterCollation` reading `MTGA_Data/Downloads/ALT/ALT_Booster_*.mtga` and stamped as `source_id` so the UI renders e.g. "BLB pack opened" instead of generic "Pack opened")
- Companion legality verification — **reader+**

## D. Live tracking (continuous reads — new architectural mode)

`Scry2.LiveState` plumbing **shipped (Chain 1 + Chain 2)**: GenServer
polls 500 ms on `MatchCreated → MatchCompleted`, persists
`live_state_snapshots`, broadcasts `live_match:updates` /
`live_match:final`. Settings toggle + setup-tour step ship the kill
switch. Chain 1 (rank/screen-name/commander) and Chain 2 (per-zone
board state — battlefield/hand/graveyard/exile, both players) are both
live; `walker/card_holder.rs` + `list_t.rs` + `card_layout_data.rs`
do the final drill-down. See `specs/2026-05-03-chain-2-board-state-design.md`
(status: shipped) and CHANGELOG v0.29.0–v0.30.1.

- LiveView UI consuming `live_match:updates` (rank/screen-name/commander) — **✅ shipped** (`Scry2Web.Components.LiveMatchCard` on `/matches`)
- Opponent (and own) revealed cards — battlefield, hand (revealed-only), graveyard, exile — **✅ shipped** (`Scry2Web.Components.RevealedCardsCard` on the match detail page; captured live, persisted at wind-down via `LiveState.record_final_board/2`). Stack and command zone deliberately unwalked (rarely populated at end-of-match / no Brawl-Commander play); library is fundamentally unreadable — the client never has unrevealed identities.
  - **Known bug, fixed 2026-07-21:** opponent hand cards were showing as "revealed" when MTGA never actually revealed them (blank/broken card images). Root cause: `card_layout_data.rs`'s reveal filter checked a `FaceDownState` field that does not exist on `CardLayoutData` in current MTGA builds (confirmed live via `walker_debug_class_fields`) — the check silently defaulted to "revealed" on every entry, so the real gate was just `IsVisibleInLayout`, which is also true for un-revealed cards (it means "occupies a rendered slot," not "shown to the player"). Fixed by gating on a resolved nonzero `BaseGrpId` instead — MTGA only ever populates that when the card's identity has genuinely been shown. Forward-only fix (does not backfill historical `arena_id=0` rows already in the DB).
  - **Fixed 2026-07-22 — battlefield per-card ownership.** Every battlefield card used to land in an unattributed "Unknown" bucket in the UI (`match_board_view.ex`'s `seat_label(0)`) instead of being split between "You" and "Opponent." Confirmed via DB query before the fix: `live_match_revealed_cards` had 8,685 battlefield rows, 100% at `seat_id=0`.
    - **Root cause:** the original design (`specs/2026-05-03-chain-2-board-state-design.md`, sub-project 4) planned a per-seat region traversal (`BattlefieldLayout.Layout`'s 8 `_local*`/`_opponent*` `BattlefieldRegion` fields), but the shipped implementation instead walked the simpler `BattlefieldLayout._unattachedCardsCache` — a single flat `List<DuelScene_CDC>` not split by player — and confirmed live that `PlayerTypeMap` only ever has one battlefield holder, keyed `0`: there's no per-seat holder to key off of for this zone the way there is for Hand/Graveyard/Exile.
    - **Fix path, confirmed live 2026-07-22** via a new spike binary (`native/scry2_collection_reader/src/bin/class_fields_probe.rs`, added this session — dumps a class's field manifest by name, or walks Chain 2 straight to real battlefield cards and dereferences fields) against 19 real battlefield cards in an active game:
      - `CardInstanceData` (the doc's conceptual name) is actually named **`MtgCardInstance`** at runtime, with `Owner` at offset `0xe0` (reference-typed, resolves to an **`MtgPlayer`** object).
      - The `MtgPlayer` pointer itself churns across GRE update batches (not stable per player), but **`MtgPlayer.ClientPlayerEnum`** (offset `0x13c`, i32) is stable: every one of the 19 cards resolved to `1` or `2`, the same `GREPlayerNum` encoding (`LocalPlayer=1, Opponent=2`) `match_scene.rs` already uses for the outer `PlayerTypeMap` seat key on Hand/Graveyard/Exile — so it drops straight into the existing seat_id scheme, no format change needed downstream.
    - **Implementation (TDD, `native/scry2_collection_reader/src/walker/card_holder.rs` + `run.rs`):** added `owner_seat_for_cdc` (drills `_model → _instance → Owner → ClientPlayerEnum`, sharing the `_model`/`_instance` prefix with `arena_id_for_cdc` via a new `card_instance_addr_for_cdc` helper) and `read_battlefield_cards` (returns `(seat_id, arena_id)` pairs per card instead of a flat arena_id list; `seat_id` defaults to `0`/unknown only when a card's owner chain fails to resolve). `run.rs`'s `push_zone_cards` helper (shared by `walk_match_board` and its cached variant) special-cases the battlefield zone: groups cards by resolved seat and emits one `ZoneCards` row per seat, instead of one row inheriting the meaningless outer-dict seat. No Elixir/NIF/persistence changes needed — the wire shape (`seat_id, zone_id, arena_ids`) was already exactly this per-row.
    - **Verified end-to-end 2026-07-22** against the real production code path (`walker::run::walk_match_board`, the exact function the NIF calls) in an active live match: battlefield now cleanly splits into `seat_id=1` (5 cards) and `seat_id=2` (9 cards) instead of one `seat_id=0` bucket. 284/284 Rust unit tests pass (new: `owner_seat_for_cdc_resolves_client_player_enum`, `owner_seat_for_cdc_returns_none_when_owner_field_missing`, `read_battlefield_cards_returns_arena_id_and_seat_pairs`), `cargo clippy --lib -- -D warnings` clean, `mix precommit` clean (2956 tests, 0 failures), `scry-2` service restarted and healthy. Forward-only — does not backfill the 8,685 historical `seat_id=0` battlefield rows already in the DB (no backfill requested).
- Active match HUD feed (life, hand, library, gy, exile, mana, stack) — **live** + **reader+** (per-tick board history was explicitly deferred when Chain 2 shipped — only the final snapshot is persisted; a HUD needs the tick broadcast, not new walker work)
- Real-time draft pack reader (cards seen but passed) — **live** + **reader+**
- Real-time mana / card-advantage tracker — **live** + **reader+**
- Opponent disconnect / concede early-detection — **live** + **reader+**
- Active-screen detection (lobby / deckbuilder / match / store) — **live** + **reader+**

## E. Forecasting (snapshot-stream analytics)

All gated on walker phase 6 producing a stream of currency/progression rows.

- Vault opening ETA from vault-progress slope — **walker**
- Mastery pass completion ETA vs season end — **✅ shipped** (`Scry2.Economy.Forecast.mastery_eta/2` projects tier at season end from XP-per-day rate; rendered as a one-liner on the `MasteryCard` on `/economy`)
- Currency burn-rate dashboard (gold/gems/wildcards over time) — **walker**
- Quest-reroll EV calculator — **walker** + **reader+**
- Win-track velocity / weekly reward attainment — **walker** + **reader+**

## F. Alerting / pre-action guardrails

- Wildcard floor alarm before a craft drops below threshold — **✅ shipped** (`Scry2.Economy.WildcardFloors`; wildcard stat-card values turn amber on `/economy` when at or below the rarity floor — common 50, uncommon 30, rare 15, mythic 5)
- Rank-decay countdown around month rollover — **reader+**
- MTGA build-change alert (revalidate parser/walker) — **✅ shipped** (`Scry2.Collection.BuildChange.detect/2`; warning banner on `/settings` with an Acknowledge button when the latest snapshot's `mtga_build_hint` differs from the user-acknowledged build)
- Cosmetic-on-sale-you-don't-own alert — **reader+**
- Quest-about-to-expire alert — **reader+**

## G. Brewing / deck library

- Deck library mirror (every saved deck in MTGA) — **reader+**
- Deck history / auto-backup on every change — **reader+** + **live**
- Sideboard awareness per deck — **reader+**
- Brew-in-progress capture for real-time companion UI — **reader+** + **live**

## UI: deck rendering engine (UIDR-012)

`Scry2Web.DeckRendering` renders every deck-shaped card list. **Converged
(2026-07-11):** deck/match/netdeck compositions, draft pool, draft pick
packs (picked-card overlay), revealed-cards card (per-zone views in
memory order), and deck version diffs (added/removed overlays).

Pending: UI controls that let the user pick a `ViewSpec` per page
(grouping, text/images, splay depth) persisted via `Settings.Entry`.

## UI: netdeck variant matrix (UIDR-014)

A "Variant matrix" section on `/netdecks/:id` below the Variants list:
contested nonland cards (rows, most-contested first) × every other
cluster member (columns, best finish first), cells `+N`/`−N` vs the
viewed deck, blank = same. Frozen card-name + `you ×N` pane; horizontal
scroll for the field; `Manabase ±N` / `Sideboard ±N` / `Total Δ` footer
rows. Pilot names must stay searchable DOM text. Name-identity diffing;
re-anchors on navigation. Supersedes the UIDR-013 per-row delta lines
(never built); design and degenerate cases in UIDR-014.

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
- **Live-state GenServer — ✅ shipped (Chain 1 + Chain 2).** `Scry2.LiveState.Server`
  polls every 500 ms while a match is active, gated by the
  `live_match_polling_enabled` Settings flag (on by default, configurable
  in setup tour and Settings → Memory Reading). Chain 1 reads
  rank/screen-name/commander via `MtgaMemory.walk_match_info/1`. Chain 2
  reads per-zone board state via `MtgaMemory.walk_match_board/1`,
  persisted at wind-down and rendered as "Revealed cards" on the match
  detail page.
- **Reader extensions** (`reader+`) — each new memory structure (rank object,
  deck list, quest list, etc.) needs its own walker-style traversal. Current
  scanner only finds the cards dictionary. Each extension is its own ADR.
