---
status: accepted
date: 2026-07-11
---
# Netdeck Import Browser

## Context and Problem Statement

Netdeck ingestion has two disconnected surfaces: a paste-only import form
and a blind daily fetch that pulls the newest MTGO events without the user
ever seeing what is available. There is no way to browse the source
(mtgo.com/decklists lists recent events per format), no way to choose which
events enter the catalog, no way to reach events the per-run cap skipped,
and no way to turn the automated fetch off. As more sources and formats
arrive, a paste box plus an invisible cron cannot carry the feature.

## Decision Outcome

Chosen option: "one import panel with paste and browse modes, event-granular
import, source-declared formats, and configurable auto-fetch", because it
makes ingestion visible and chosen rather than blind, collapses the parallel
"Fetch now" path into a single mechanism, and gives source/format growth a
structural home.

* **One panel, two modes**: paste (existing form) and browse are tabs of a
  single import panel — a growable surface, not a `<details>` disclosure row.
* **Browse flow**: source picker → format picker → recent events from the
  source's landing page, newest first, showing name, date, player count when
  known, and an "imported" marker for events already in the catalog.
* **Formats are declared by the source**: the format selector renders only
  what the chosen source declares. mtgo declares only `standard` today; the
  selector may show a single fixed entry. The catalog remains Standard-only
  — the selector is structural, not a multi-format catalog.
* **Event-granular import**: selecting events imports every decklist in
  each. No deck-level cherry-picking — clustering needs the full field of
  variants to group archetypes. Re-importing an event is idempotent.
* **Configurable auto-fetch**: per-source on/off toggle, default on,
  persisted as a setting. Off means the catalog changes only through the
  browser. The standalone "Fetch now" button is absorbed by the browser —
  it was "import the newest events", which is now an explicit action.
* **Errors are visible**: a failed landing or event fetch surfaces an
  inline error in the browser, never a silent empty list.

## Sequencing

Ships before the provenance reingest (UIDR-010): when the netdeck catalog
is cleared and rebuilt, the rebuild happens through the browser with
visible, chosen events, and everything returns with structured provenance.

### Consequences

* Good, because the user sees and chooses what enters the catalog, and can
  reach events the automated cap skipped.
* Good, because one import mechanism replaces three surfaces (paste form,
  Fetch now button, invisible cron) — one code path to test and reason about.
* Good, because new sources and formats have a structural home instead of
  requiring new UI.
* Bad, because the import panel is more complex than a paste box — two
  modes, remote state, loading and error states.
* Bad, because a single-format selector today looks vestigial until more
  formats or sources arrive — accepted as the cost of the structural slot.
