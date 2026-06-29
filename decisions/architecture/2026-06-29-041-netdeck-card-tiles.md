---
status: accepted
date: 2026-06-29
---
# 041. NetDeck catalog — read-time clustering + derived labels + all-art tiles

## Status

Accepted

## Context and Problem Statement

The `/netdecks` catalog listed every ingested deck as a text row. Because the
MTGO source ingests **every player's list from each event** (32 players per
Standard Challenge), the catalog was dominated by near-duplicate decks of the
same few archetypes — and MTGO provides no archetype name, so rows were labeled
by meaningless player handles. The user could not identify decks at a glance.

The goal: a tile grid that surfaces a deck's qualities (color identity, signature
cards, buildability) and **collapses near-duplicates into distinct, labeled
tiles**, without inventing data we don't have and without losing any deck row.

## Decision

**Read-time near-duplicate clustering.** `Scry2.NetDecking.DeckClusters.group/2`
groups decks by Jaccard similarity on each deck's **nonland card set** (the
spells define the archetype; lands/basics are excluded). Threshold defaults to
**0.7** (`netdecking_cluster_threshold`, tunable). Validated on the live corpus:
**126 decks → 44 distinct tiles**. Every deck row stays in the DB — clustering
happens in `catalog/0` at read time, like buildability (disposable read model,
data-integrity rule preserved). The cluster's **member count** (`×N lists`)
becomes a meta-popularity signal, and the **representative** is the
lowest-wildcard-cost member (most buildable for the user).

**Derived labels, not a taxonomy.** Tiles are labeled `color-combo · signature
card` (e.g. "Jeskai · Improvisation Capstone"). The color-combo name is the
**canonical name of the color identity** (Boros, Jeskai, Esper…), derived purely
from `cards_cards.color_identity` — not a fabricated archetype label (we have no
archetype data). The signature card is the deck's highest-rarity nonland card.

**All-illustration tiles.** Each tile shows a hero **art crop** + 3 micro art
crops (the deck's top-4 nonland cards by rarity → mana value), plus mana pips
(`mana_pips`), the newest set's symbol (`set_icon`, the set contributing ≥2
cards), `×N`, buildability, and a sideboard badge. No card frames — at small
sizes the illustration is recognizable where a full card is unreadable.

**`ImageCache` art variant.** `image_uris["art_crop"]` is stored for every card
but `ImageCache` cached only the full card. It now serves a second `:art`
variant (`url_for(id, :art)` → `/images/cards/{id}-art.jpg`), backward-compatibly
(existing full-card callers unaffected). The detail page keeps the full card.
The catalog downloads art crops **off the request path** via `start_async` so a
first-view cache miss (~170 crops) never blocks the render.

## Consequences

- The catalog is now scannable: 44 recognizable archetype tiles instead of 126
  near-identical rows, each carrying real qualities.
- Pure, tested derivation (`DeckQualities`, `DeckClusters`) keeps the LiveView
  thin; the buildability engine and ingestion are untouched.
- **Accepted deviation from the design spec:** the representative tie-break is
  simplified to lowest-cost + deterministic list order (decks are name-ordered),
  rather than the spec's `cost → owned_pct → fetched_at`. For near-identical
  cluster members the representative is nearly interchangeable; the simpler rule
  is deterministic and was not worth additional complexity.
- Two real-data edge cases surfaced in live verification and were fixed:
  `newest_set_code/3` crashed on sets with a `nil` `released_at` (MTGA-only sets
  lacking Scryfall dates); and the catalog originally cached art synchronously,
  blocking the first view — now backgrounded.
- Art crops roughly double the catalog's image-fetch load on first view; lazy
  `loading="lazy"` + placeholder + background fetch absorb it, and crops are
  cached immutably thereafter.
