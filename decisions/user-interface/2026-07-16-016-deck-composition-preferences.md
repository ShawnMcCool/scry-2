---
status: accepted
date: 2026-07-16
---
# Deck Composition Preferences — One Struct, Per-Section Controls

## Context and Problem Statement

`standard_composition` rendered its two sections in a fixed order (text
list above image stacks) with fixed groupings (text by card type, images
by mana value), even though the engine's `ViewSpec.group_by` already
supports both vocabularies for either display. The one existing user
preference — `display_mode` (Text / Images / Both) — was a bare atom
persisted at its own Settings key (`deck.display_mode`).

The user wants to control which section is on top (default: images) and,
independently per section, whether it groups by type or by mana value.
Adding these as more loose assigns and Settings keys would scatter one
idea — "how the standard composition renders" — across four
representations.

## Decision Outcome

Chosen option: "promote the preference to a single value type,
`CompositionPrefs`, with controls living in each section's header",
because the composition preference is one idea and should have one
representation, one serialization, and one owner.

* **`Scry2Web.DeckRendering.CompositionPrefs`** — `display_mode`
  (`:text | :images | :both`), `top` (`:images | :text`, default
  `:images` — flipping the previous text-first order), `text_group_by`
  and `images_group_by` (`:type | :mana_value`, defaulting to each
  section's traditional vocabulary). Every field is whitelist-parsed;
  the struct subsumes the old `parse_display_mode/1` / `displays_for/1`
  pair.
* **One Settings key.** The struct persists as a string map under
  `deck.view_prefs`, owned by `DeckViewScope`. The legacy
  `deck.display_mode` entry seeds `display_mode` on installs that have
  it and is deleted on the first preference write — no deprecated keys
  left behind.
* **One event.** All controls emit `set_deck_view_pref` with
  `field` + `value`; `CompositionPrefs.put/3` is the single whitelisted
  setter. The mode-specific `set_deck_display_mode` event is retired.
* **Controls live in section headers.** Each section header row carries
  its own Type/Mana grouping toggle plus a swap (⇅) button flipping
  which section is on top; the swap renders only when both sections are
  visible. The global Text/Images/Both toggle stays top-right. Styled
  per UIDR-008 — soft join groups, never solid fills.
* **The engine is untouched.** Both groupings were already `ViewSpec`
  parameters (UIDR-012); this decision only adds preference state and
  controls over them.

### Consequences

* Good, because the grouping control sits on the thing it affects — no
  mystery mapping from a distant control cluster to a section.
* Good, because future composition axes (e.g. per-section piling) are a
  field on an existing struct, not a new Settings key and event.
* Neutral, because the preference is global across all deck renderings
  (deck page, match detail, netdecks), matching the existing
  display-mode behavior.
* Bad, because the section headers now carry chrome on every deck
  render, accepted as the cost of discoverability.
