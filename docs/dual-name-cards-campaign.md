# Campaign: dual-name (Universes Within) card aliases

**Status:** not started · **Opened:** 2026-07-16 · **Owner:** Shawn + Claude

## Why this work is needed

Universes Beyond cards with Universes Within twins exist on Arena as two
printings with two names — e.g. "Spider-Sense" (SPM, arena 97862) and
"Detect Intrusion" (OM1, arena 104694). The naming authorities disagree:
Scryfall names OM1 printings by their oracle (Marvel) name and keeps the
Within name only in `flavor_name` (a field our mirror doesn't store);
the MTGA client DB and mtgo.com decklists use the Within names.

Because synthesis prefers Scryfall's name, the Within names exist
nowhere in `cards_cards`. Consequences today:

- **Netdeck ingestion** can't resolve MTGO-published Within names —
  decks show "N card(s) weren't recognised" and those cards aren't
  scored for buildability.
- **Archetype classification** (ADR-043) can't match conditions written
  against Within names — upstream MTGOFormatData mixes both naming
  conventions, so affected decks classify weaker or wrong.
- Any future name-based feature inherits the same blind spot.

Full diagnosis: ADR-043 § "Known Limitation: dual-name cards".

## Planned shape (one session, roughly)

1. Mirror Scryfall `flavor_name` (schema + import; needs a bulk
   re-fetch to populate).
2. Stamp an alias name onto `cards_cards` during synthesis (Scryfall
   `flavor_name`, falling back to the MTGA-mirror name when it differs).
3. `Cards.resolve_references/1`: alias-aware name fallback.
4. `Metagame` classification: alias-expand card names on both the deck
   and condition sides.
5. One-off in-place re-resolve of stored netdecks' `unresolved_cards`
   (never re-ingest — resolving changes `composition_hash`).

## Session log

- 2026-07-16 — phenomenon diagnosed while investigating unresolved
  cards on netdeck 342; documented in ADR-043; campaign opened.
