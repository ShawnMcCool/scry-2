---
status: accepted
date: 2026-07-30
---
# DeckList shared kernel for card-list representation

## Context and Problem Statement

`decks_decks` and `netdecking_decks` persist card lists in the identical
shape — `%{"cards" => [%{"arena_id" => id, "count" => n}]}` — but parsing
and name-identity logic existed as five partial copies: `Decks.CompositionIdentity`,
a private parser inside `Decks.composition_hash/1`, `NetDecking.CompositionKey`,
`NetDecking.OwnedIdentity`, and `NetDecking.VariantMatrix` (plus two more
private `card_entries` parsers along the way). Each copy re-derived the
same card-identity rule — downcased, trimmed card name — independently.

Identity edge cases had to be found and fixed per copy. The v0.52.6 fix
for `<nobr>`-wrapped mirror names in alias resolution is one example:
name-identity bugs are a class, not a one-off, and five copies meant five
places a fix could land, with no guarantee all five were caught.

Card search (this campaign) needed name facets — `card_names` per group
and a corpus-wide `card_index` — derived from the same entries. Building
that directly against the persisted shape would have been a sixth copy.

## Decision Drivers

* One card-identity rule must exist in exactly one place — the app has
  already paid for divergence once (the mirror-name fix) and card search
  would have made it worse.
* Persisted identities (`composition_hash`, `composition_key`) cannot
  change value as a side effect of consolidation — they are load-bearing
  (a unique index, an equality join across deck versions).
* Bounded contexts still need purpose-specific outputs from the same
  entries — Decks' stored hash and NetDecking's dedup digest are not the
  same kind of value and must not be forced into one shape.

## Considered Options

* Leave the five copies in place; add a sixth for card search facets
* Pick one context (e.g. NetDecking, which had the most complete parser)
  to own card-list parsing and have Decks call into it
* Extract a pure shared kernel, owned by no bounded context, that both
  contexts call

## Decision Outcome

Chosen option: extract a pure shared kernel, `Scry2.DeckList`, because
card-list representation and card-identity are not bounded-context
concerns — they are a shape and a rule that both contexts already agree
on and neither should own on the other's behalf.

`Scry2.DeckList` owns representation and identity only:

* `entries/1` — parses the stored map (or a bare card list) into
  `%{arena_id, count}` entries; shapeless input parses as empty.
* `identity_key/1` — the one card-identity rule everywhere: downcased,
  trimmed card name.
* `canonical_pairs/2` — printing collapse: sums counts across printings
  sharing a representative arena_id.
* `name_keys/2` — the set of card-identity keys named by a list of
  entries, resolved through a `cards_by_arena_id` map. This is what the
  card search facets are built from.

Purpose-specific outputs stay in their contexts, now as thin layers over
the kernel:

* `Scry2.Decks.composition_hash/1` keeps its stored integer hash
  (deliberately unsummed raw pairs — it is not `canonical_pairs/2`'s
  representative-summed shape).
* `Scry2.NetDecking.CompositionKey` keeps its SHA-256 dedup digest.
* `Scry2.NetDecking.OwnedIdentity` keeps ownership aggregation against
  the collection.
* `Scry2.NetDecking.VariantMatrix` now calls the kernel instead of
  re-parsing entries itself.
* `Scry2.Decks.CompositionIdentity` is deleted — fully absorbed.

The kernel is pure: no DB access, no PubSub, no context dependency. It is
owned by no bounded context in the `## Bounded Contexts` sense — it does
not appear in that table, has no tables of its own, and publishes no
events. This is the shared-kernel pattern (Evans, DDD), not a violation
of "no context aliases another context's modules": that rule governs
context-to-context calls; a shared kernel with no context identity is
callable by any context, by design.

### Compatibility gate

Both persisted identities are frozen by golden tests with captured
literal values: `composition_hash` on `decks_decks`, and
`composition_key` (unique-indexed) on `netdecking_decks`. See
`test/scry_2/deck_list_golden_test.exs`. The refactor was verified
bit-for-bit output-preserving against these literals before any of the
five copies were removed. The golden file's captured literals are never
updated to make a change pass — a literal mismatch means the code
changed identity-relevant behavior; fix the code, not the test.

### Consequences

* Good: one fix point for card-identity edge cases (e.g. the
  Unicode-downcase mirror-name class of bug) instead of five.
* Good: decks-page card search is adoption of existing `DeckList`
  facets, not a rewrite — the sixth copy was never written.
* Neutral: the kernel must never grow DB access, PubSub, or a
  purpose-specific output (a hash, a digest, an aggregation). Any of
  those belongs in a context, not the kernel. Growing the kernel that
  way is the rot vector for this design and should be rejected in
  review.
* Bad (known caveat, pre-existing and not introduced by this campaign):
  `identity_key/1` downcases with Unicode `String.downcase/1`, while
  `Scry2.Cards.printings_by_name/1` keys by SQL `lower()`, which is
  ASCII-only. The two diverge for uppercase non-ASCII letters. Today
  this affects four Éomer/Éowyn printings, none Standard-legal, so it
  has no live consequence — but any future consumer that joins
  `identity_key/1` output against `printings_by_name/1` keys inherits
  the mismatch and should be aware of it.
