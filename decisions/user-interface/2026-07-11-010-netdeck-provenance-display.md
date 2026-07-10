---
status: accepted
date: 2026-07-11
---
# Netdeck Provenance Display

## Context and Problem Statement

MTGO decklist pages publish rich competitive metadata per deck — pilot, swiss
standing, playoff placement, win/loss record, event name, event date — but
ingestion mashed event + pilot into a single `name` string and discarded the
rest. The catalog tile showed only a generated archetype label
("Jeskai · Improvisation Capstone"), and the detail page's h1 was the mashed
name string. Neither told the user whether an archetype was competitively
proven, and the ×39 variant count on a tile was a dead end — variants were
unreachable from the UI.

A netdeck catalog tile represents a *cluster* of near-duplicate decks from
many pilots and events, and the cluster's representative is whichever variant
is currently cheapest for the user to build — it changes as the collection
changes. Any title derived from one variant (pilot, event) would therefore
silently mutate over time.

## Decision Outcome

Chosen option: "archetype label stays the title; provenance is a structured
subtitle everywhere", because it is the only titling scheme that is stable
across the whole cluster, and it turns discarded source data into a
first-class quality signal without fabricating anything.

* **Titles**: the generated archetype label (color combo · representative
  card) is the title on both the catalog tile and the detail page h1. The
  title the user clicks is the title they land on.
* **Tile subtitle**: one muted line under the title with the cluster's best
  finish, event name, and event date — e.g. `1st · Standard Challenge 32 ·
  Jun 26`. Best finish = lowest playoff `final_rank` across the cluster;
  if no variant made playoffs, best swiss rank rendered honestly as
  `9th of 42`. Clusters with no placement data omit the line entirely.
* **Detail provenance line**: pilot, finish, event, event date, W-L record,
  and an external link to the source decklist page — e.g. `Venom01 — 1st ·
  Standard Challenge 32 · Jun 26, 2026 · 7-2 · mtgo.com ↗`. Missing fields
  are omitted and separators collapse.
* **Variant browser**: a Variants section on the detail page lists every
  cluster member (pilot, finish, record, date, per-variant wildcard cost),
  sorted playoff finish first, then swiss rank, then buildability. The
  currently viewed variant is marked; rows navigate to that variant's
  detail. Every cluster member's detail page shows the full list.
* **Voice**: placement renders in the muted subtitle voice — no solid or
  gold badges (per UIDR-001 badge convention and UIDR-008 no-solid-fills).
  Swiss tiebreaker percentages (score, OMW%, GW%) stay out of the UI.

### Consequences

* Good, because the user can judge whether an archetype is competitively
  proven from the catalog, and pick the variant that actually won instead
  of only the cheapest one.
* Good, because every deck is traceable to its verifiable source page —
  trust through traceability rather than decoration.
* Good, because titles never mutate as the collection changes.
* Bad, because tiles with provenance gain one line of height.
* Bad, because sources without competitive metadata (manual paste, local
  JSON) render with visibly sparser tiles and headers — accepted; absence
  of data is shown as absence, never as a placeholder.
