# Metagame Archetype Classification via Community Definitions

## Context and Problem Statement

Deck archetypes have culturally established names — "Izzet Prowess,"
"Dimir Midrange," "Domain" — and Scry2 didn't use them. The netdecks
catalog invented a synthetic label (`color combo · hero card`) and
titled decks by event/pilot, player decks had no archetype at all, and
opponents' decks were never classified, making matchup analysis by
archetype impossible. How should Scry2 name and classify decks?

## Decision Drivers

- Names must match what players actually call these decks — invented
  labels have no currency.
- The meta shifts every set release; a hand-curated mapping goes stale.
- One vocabulary must serve three consumers: netdecks (full lists),
  player decks (full lists, versioned), and opponents (partial
  information from revealed cards).
- Archetype must be a SQL-queryable dimension (future matchup stats).

## Considered Options

- Community rules data (Badaro's MTGOFormatData) + own classifier engine
- Own curated definitions file
- Scraping labeled sites (MTGGoldfish metagame pages)
- Emergent cluster naming (user names clusters once)

## Decision Outcome

Chosen option: **community rules data + own engine**, in a new
`Scry2.Metagame` bounded context.

- **Definitions**: [MTGOFormatData](https://github.com/Badaro/MTGOFormatData)
  — actively maintained, per-format JSON archetype rules with the names
  the community uses, card references by name (fits the existing
  name-identity approach). A vendored snapshot under `priv/metagame`
  seeds first run; `Workers.PeriodicallyFetchArchetypeDefinitions`
  refreshes daily from the repo tarball (one HTTP request), rejecting
  fetches that parse to zero archetypes so a bad download can never
  wipe the vocabulary.
- **Engine**: `Metagame.ClassifyDeck` is a pure port of
  MTGOArchetypeParser semantics (verified against its C# source):
  condition types, variants, prefer-simpler conflict resolution,
  common-cards fallbacks (>0.1 similarity), color detection requiring a
  color in both lands and nonlands, `IncludeColorInName` composition.
  Card colors come from our own Cards data (`color_identity`,
  `is_land`) plus the format's `color_overrides.json`.
- **Partial-information mode** (our extension): for opponents, observed
  cards satisfy inclusion conditions or leave them undecided (never
  failing); exclusions disqualify only when the excluded card was seen;
  results carry `:confirmed`/`:likely` confidence and admit `:unknown`
  rather than guess.
- **Stamped classifications** (ADR-027 precompute): NetDecking stamps at
  ingest, `Decks.DeckProjection` stamps deck + version on `DeckUpdated`,
  and `Matches.ClassifyOpponentArchetype` (a `live_match:board_final`
  consumer) stamps `opponent_archetype` post-match. All stamps are
  disposable projections; `Workers.ReclassifyArchetypes` re-stamps all
  three contexts when definitions change.
- **Display**: the classified name replaces netdeck display names
  (cluster tiles title by member majority); event/pilot demotes to
  provenance (UIDR-010). The synthetic label survives only as the
  fallback for unclassified decks.

Standard-only for now; Limited matches are never classified.

### Deck naming policy

The classified archetype name is the **display name** for any deck that
has one, everywhere decks are titled:

- Netdeck catalog tiles and detail pages title by archetype
  ("Izzet Prowess"); the stored `name` (event — pilot) and the
  source-provided `archetype` string are provenance, shown subordinate
  (UIDR-010). The source archetype badge renders only when it differs
  from the classified title.
- Cluster tiles title by the majority classification over members —
  never by one variant's metadata.
- Unclassified decks fall back to the synthetic `color · hero card`
  label. The synthetic label is a fallback only; it must never override
  a classification.
- Player decks keep their user-chosen MTGA name as the title; the
  archetype renders as a badge beside it. We name what we classified —
  we don't rename what the player named.

### Consequences

- Good: archetype names players recognize, kept current by the
  community as the meta moves; one vocabulary across catalog, own
  decks, and opponents; plain SQL matchup aggregation becomes possible.
- Good: classification is a pure function over durably stored inputs —
  reclassification is always safe and cheap.
- Bad: a dependency on an external repo's data quality and continuity
  (mitigated by the vendored seed, the zero-archetype guard, and
  keeping prior rows on fetch failure).
- Bad: partial-information confidence thresholds are heuristic and will
  need tuning against real match data.

## Known Limitation: dual-name (Universes Within) cards

Discovered 2026-07-16. Universes Beyond cards with Universes Within
twins exist on Arena as **two printings with two names** — e.g.
"Spider-Sense" (SPM #46, arena 97862) and its Omenpaths twin
"Detect Intrusion" (OM1 #28, arena 104694). The naming authorities
disagree per printing:

- **Scryfall** names OM1 printings by their oracle (Marvel) name and
  carries the Within name only in `flavor_name` — a field our Scryfall
  mirror does not store.
- **The MTGA client DB** names the OM1 printings by their Within name.
- **mtgo.com decklists** publish the Within names (MTGO has no Marvel
  license).

Synthesis prefers Scryfall's name, so the Within names
("Detect Intrusion", "Ademi of the Silkchutes", …) exist nowhere in
`cards_cards` — `Cards.resolve_references/1` cannot resolve them
(netdecks report them as unrecognised), and archetype conditions
written against Within names can never match.

Planned fix (not yet implemented): treat the two names as **aliases of
one printing** — mirror Scryfall `flavor_name`, stamp it into
`cards_cards`, extend name resolution to fall back to alias and
MTGA-mirror names, alias-expand names during classification, and
re-resolve stored netdecks' `unresolved_cards` (noting that resolving
previously-unresolved cards changes `composition_hash`, so the
re-resolve pass must update rows in place rather than re-ingest).
