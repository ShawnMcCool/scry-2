# scry_2 — capability roadmap from MTGA memory reading

A living tracker of capabilities unlocked by reading MTGA's process memory,
beyond what `Scry2.Collection` already does (cards dictionary snapshot via
the structural scanner). Each item is tagged with its prerequisite:

- **today** — buildable now with the existing scanner output
- **walker** — gated on walker phase 6 (wildcards, gold, gems, vault, build hint)
- **live** — gated on a new continuous-poll subsystem (no GenServer yet)
- **reader+** — gated on extending the memory reader to a new structure

This is a brainstorm tracker, not a commitment. Order is not priority.

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

## B. Reconciliation (memory-vs-log truth diffing)  ← FOCUS

- Currency reconciliation (memory wildcards/gold/gems vs log `InventoryUpdated`) — **walker**
- Booster-count reconciliation (memory pack inventory vs log pack events) — **walker** + **reader+**
- Log-gap detector (currency change observed in memory but no matching log event) — **walker**
- Deck-list reconciliation (memory deck vs log-submitted deck) — **reader+**
- "Verify everything" admin button (runs every reconciliation) — composes above

## C. Pre/post-match capture (one-shot reads at known transitions)

- Pre-match deck snapshot when log fires `MatchCreated` — **reader+**
- Pre-match opponent snapshot from lobby memory — **reader+**
- Post-match economy delta (memory snapshot before/after match) — **walker**
- Pack-open card capture (memory snapshot before/after pack open) — **today**
- Companion legality verification — **reader+**

## D. Live tracking (continuous reads — new architectural mode)

Requires a `Scry2.LiveState` GenServer polling at ~4 Hz during active match
or draft. New PubSub topic. New isolation gate (settings flag, like the
reader-enabled flag).

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

- **Walker phase 6** — unlocks wildcards, gold, gems, vault progress, build
  hint. Spec'd in `decisions/research/2026-04-21-001*` and ADR 034. Most B/E/F
  items wait on this.
- **Live-state GenServer** — does not exist. Currently snapshots are one-shot.
  Adding a poll loop is a deliberate architectural step (settings flag, kill
  switch, isolation gate) — not a casual addition.
- **Reader extensions** (`reader+`) — each new memory structure (rank object,
  deck list, quest list, etc.) needs its own walker-style traversal. Current
  scanner only finds the cards dictionary. Each extension is its own ADR.
