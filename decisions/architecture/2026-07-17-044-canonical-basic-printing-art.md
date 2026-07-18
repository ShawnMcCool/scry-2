# Card images always render the most basic printing's art

## Context and Problem Statement

MTGA and decklist sources reference specific printings — showcase,
borderless, promo, and flavor-name treatments each carry their own
`arena_id` and collector number. Card images were resolved per
`arena_id` through a three-path fallback query joining the Scryfall
mirror at read time, so whatever printing a source happened to name (or
an arbitrary per-name pick in `Cards.resolve_references/1`) determined
the art the app displayed. Special-art printings appeared throughout
the UI, and the flavor-name demotion rule existed twice: as SQL in the
image lookup and as `MergeFields.prefer_canonical_printing/2`.

## Decision Drivers

* Scry2 renders *cards*, not *printings* — one card identity should
  look the same everywhere.
* Projections precompute derived values at write time; read paths stay
  trivial (established project rule).
* One representation per idea — the canonical-printing rule must live
  in exactly one place.

## Considered Options

* Rank printings by basicness inside the read-time image lookup
* Normalize representative `arena_id`s at netdecks ingestion
* Stamp canonical display art onto `cards_cards` at synthesis time

## Decision Outcome

Chosen option: stamp at synthesis time.

* `Scry2.Cards.BasicPrinting` is the single ranking rule: flavor-name
  overlays last, then not-promo, not-full-art, not-variation, no frame
  effects, black border, in-booster; numeric collector number and
  earliest release as tiebreaks. Unknown metadata ranks as basic.
* The Scryfall mirror stores the treatment fields (`promo`,
  `full_art`, `variation`, `frame_effects`, `border_color`) from bulk
  data, and falls back to `card_faces[0].image_uris` for double-faced
  layouts.
* `Cards.Synthesize` stamps `image_url` / `art_crop_url` onto every
  `cards_cards` row from the most basic printing sharing the card's
  name (per URI kind, so image gaps fall through to the next-most-basic
  printing). Token rows never donate art.
* `Cards.get_image_url_for_arena_id/1` and `get_art_url_for_arena_id/1`
  are column reads. The three-path fallback query and its flavor-name
  CASE hack are deleted; `prefer_canonical_printing/2` is absorbed into
  `BasicPrinting`.
* `ImageCache` versions its directory (`cache-version` marker, now v2).
  The turnover is deferred until the read model actually carries
  stamped art (`Cards.display_art_stamped?/0`), checked on the
  `ensure_cached/2` read path — clearing earlier would re-cache
  literal-printing art from the live-API fallback under the new
  version. `Cards.Bootstrap` treats "synthesised but never stamped"
  (with Scryfall data present) as needing synthesis, so installs
  converge at boot rather than on the daily cron.

### Consequences

* Good: every card image — deck pages, netdecks, collection, hover
  popups, art chips — is the basic printing's art, with zero view
  changes.
* Good: the image read path lost all its cleverness; the ranking rule
  exists once and is unit-tested.
* Neutral: owned special versions render as their basic printing; this
  is the intended "one rule, no exceptions" scope.
* Neutral: brand-new cards (bulk data lag) briefly show their literal
  printing via the live-API fallback until the next import + synthesis.
* Open point (out of scope here): `Cards.resolve_references/1` still
  picks an arbitrary printing per name for name-only references. That
  no longer affects art, but printings can differ in **rarity**, which
  feeds netdecks wildcard math. Needs its own decision.
