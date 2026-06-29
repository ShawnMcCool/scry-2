---
status: accepted
date: 2026-06-29
---
# 040. NetDecking automated sourcing — first-party + local feed, name-identity ownership

## Status

Accepted

## Context and Problem Statement

NetDecking (the catalog of external Standard decks scored against the player's
collection) shipped with a manual MTGA-paste entry point and a designed-but-
unused `Scry2.NetDecking.Source` behaviour (`fetch/0 :: [raw_deck]`). The open
question was how to fill the catalog automatically without compromising the
project's conservative legal posture (it is open source) or its reliability.

A deep source survey (see
`docs/superpowers/specs/2026-06-28-netdecking-sourcing-research.md`, with a
live probe on 2026-06-28/29) established:

- **No surveyed source is simultaneously API-structured, Cloudflare-free, and
  shipping MTGA import strings.** Some name/set resolution is unavoidable.
- **MTGGoldfish / AetherHub / mtgdecks.net are Cloudflare-gated** (managed JS
  challenge or UA-gating); mtgdecks.net's robots.txt explicitly disallows
  `anthropic-ai`/`ClaudeBot`/`GPTBot` and its text export. Moxfield was already
  rejected. Defeating bot protection or spoofing a browser UA conflicts with a
  conservative open-source stance.
- **mtgo.com server-renders `window.MTGO.decklists.data`** — clean structured
  JSON, no Cloudflare, daily Standard Challenges, allow-all robots posture.
- **magic.gg** carries Arena-ladder decks but only as a minified Nuxt 2 IIFE
  backed by Contentful — brittle to extract.
- The probe also surfaced a latent correctness bug: collector-less sources
  (MTGO) resolve a card to *one* of its many printing `arena_id`s, but
  buildability matched ownership strictly by `arena_id`, so a card the player
  owns under a different printing read as "missing."

## Decision

**Source tier (v1):**

1. **`LocalJsonSource` — canonical, always-on.** An out-of-band JSON meta-feed
   file the maintainer authors outside the app. Zero third-party
   ToS/Cloudflare/HTML-stability risk touches the running instance, it is
   deterministic and fixture-testable, and `decklist_text` is already
   `(SET) collector` form (the cleanest resolution path).
2. **`MtgoSource` — first-party web.** Parses `window.MTGO.decklists.data` via
   the pure `MtgoExtract`. Honest User-Agent (`scry2/<version> (+repo)`), never
   a browser-UA spoof. MTGO carries no collector number, so resolution is by
   case-insensitive name.

**Deferred (documented, not built):** `MagicGgSource` (Nuxt IIFE brittleness —
needs a Contentful-angle probe), `MtgTop8Source` (opt-in HTML), `UntappedSource`
(needs a headless browser). **Rejected:** MTGGoldfish, AetherHub, mtgdecks.net,
Moxfield.

**Architecture:**

- Each source is a plain module implementing `Source` — no processes.
  `IngestSource.run/1` pipes every `raw_deck` through the unchanged
  `IngestDecklist.run/1` funnel (Parse→Resolve→Dedup→Persist), shared with
  manual paste.
- `Scry2.Workers.PeriodicallyFetchNetdecks` (Oban cron, daily 06:30 UTC) runs
  the enabled sources **in isolation**: a source that raises is logged and
  skipped so it can never abort the others or fail the cron. Because the funnel
  only upserts, a failed fetch means "no new decks," never data loss — this
  graceful degradation is a deliberate, documented exception to let-it-crash.

**Resolution correctness (two changes):**

- **Ownership by card-name identity.** `Scry2.NetDecking.OwnedIdentity`
  aggregates owned counts across every printing of a card name (via
  `Cards.printings_by_name/1`) onto the deck's representative `arena_id`. The
  pure `Buildability` engine stays `arena_id`-keyed — the context feeds it
  correctly aggregated counts. This is the MTGA-correct model (a playset is by
  card name) and matches the existing by-name precedent in
  `Collection.Completion`.
- **Front-face fallback in `Cards.resolve_references/1`.** Double-faced source
  names (`"Front // Back"`) fall back to the front face; the full-name match
  runs first, so true split cards stored with `//` still resolve to their own
  row. Benefits every source and manual paste.

## Consequences

- The catalog stays current daily with no third-party legal exposure beyond a
  first-party WotC/Daybreak source fetched politely. The local feed is the
  spine; MTGO adds freshness without touching the hostile aggregator tier.
- Name-only resolution is acceptable: every current-Standard card exists on
  Arena by name, and unresolved cards are reported (never dropped) and surfaced
  in the catalog's incomplete-resolve flag.
- HTML/JSON-shape drift on mtgo.com is the main fragility; `MtgoExtract` is pure
  and fixture-tested so drift is caught by a failing test, not silent. The
  source survey's live verdicts (Cloudflare states, robots.txt) are
  time-sensitive and should be re-checked before each release.
- The ownership-by-name change also hardens manual paste against multi-printing
  mismatches — a correctness win beyond the sourcing feature.
