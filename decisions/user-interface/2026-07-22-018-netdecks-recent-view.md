---
status: accepted
date: 2026-07-22
---
# Netdecks — Recent-Arrivals View

## Context and Problem Statement

The netdecks index (UIDR-017) groups every deck by buildability tier, then
ranks archetypes by best competitive finish. That answers "what should I
build" but has no lens for "what showed up lately" — a deck imported five
minutes ago lands wherever its tier and finish rank place it, possibly at
the bottom of "Within reach" behind decks weeks old. `fetched_at` already
exists on every deck (shown as a relative time on the detail page) but has
no dedicated view.

Separately, the import browser (UIDR-011) already surfaces "recent events
available at the source" — that is discovery of what could be imported,
not a record of what already was. The two must stay visibly distinct.

## Decision Outcome

Chosen option: **a "Recent" tab on `/netdecks` showing individual decks
ordered strictly by `fetched_at` descending**, paginated with the same
numbered-link convention already used by `matches_live` and `decks_live`
(20/page, `?page=N`, page 1 omits the param).

* **Tab, not a separate route.** A segmented control ("By status" /
  "Recent") sits at the top of `/netdecks`, state carried in `?view=recent`
  so it survives reload and back/forward, matching how `matches_live`
  encodes list state in the URL. "By status" remains the default and is
  unchanged.
* **Flat list, not grouped.** Unlike the tiered catalog, Recent lists
  individual decks — no archetype grouping, no tier sections. Order is
  `fetched_at` descending only; it is never affected by buildability
  status or wildcard/collection rescoring (`snapshot_saved` never
  reorders it).
* **Row content stays skim-level**: hero art thumbnail, archetype label +
  mana pips, small buildability status badge, source + event name/date,
  fetched-at relative time (the headline fact of this view), and wildcard
  cost pips (or an owned indicator). No archetype-core delta chips or
  variant matrix — that depth belongs to the archetype/detail pages.
* **Pagination matches existing convention.** Same numbered-link pattern
  as Matches/Decks, not infinite scroll or streams — this would be the
  only feed-like surface in the app using a different interaction model
  otherwise.
* **No search in Recent.** The search box remains scoped to "By status";
  Recent is a skim/pulse-check surface, not a filtered browse.
* **Distinct from the import browser.** "Recent" here always means
  "recently entered your catalog," never "recently played at the source."
  The import browser's event list is untouched.

### Consequences

* Good, because "what's new" no longer requires diffing the whole tiered
  catalog from memory.
* Good, because it reuses an existing, proven pagination convention
  instead of introducing a third one.
* Good, because `fetched_at` already exists — no new column, no new
  projection, purely a new read-time ordering + a flatter row.
* Neutral, because row components are a new, flatter sibling to
  `archetype_row`/`variant_row` rather than a straight reuse — the shapes
  differ enough (one deck vs. one archetype-with-variants) that forcing
  reuse would compromise either view.
* Bad, because a third near-duplicate pagination-controls implementation
  now exists (Matches, Decks, Netdecks-Recent) — extracting a shared
  component is flagged but deferred, not blocking this feature.
