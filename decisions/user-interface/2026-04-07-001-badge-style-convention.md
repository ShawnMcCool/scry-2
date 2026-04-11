---
status: superseded
date: 2026-04-07
superseded-by: 2026-04-11-008-no-solid-fill-semantic-backgrounds.md
---
# Badge style convention

> **Superseded by [UIDR-008](2026-04-11-008-no-solid-fill-semantic-backgrounds.md) (2026-04-11).**
> Solid-fill semantic badges proved too loud against the dark theme. The replacement
> rule requires `badge-soft` on every semantic badge. Content below is preserved for
> history.

## Context and Problem Statement

Scry2 uses daisyUI badges in several places — win/loss indicators, card rarity, status labels — with no documented convention for when to use which style. Without a convention, each new badge becomes a one-off decision.

## Decision Outcome

Badges use solid-fill daisyUI styles, sized `badge-sm`, with semantic color per category.

### Win/loss results

| State | Classes |
|-------|---------|
| Won | `badge badge-sm badge-success` |
| Lost | `badge badge-sm badge-error` |
| Pending/unknown | `badge badge-sm badge-ghost` |

### Card rarity

| Rarity | Classes |
|--------|---------|
| Mythic | `badge badge-sm badge-warning` |
| Rare | `badge badge-sm badge-accent` |
| Uncommon | `badge badge-sm badge-info` |
| Common | `badge badge-sm badge-ghost` |

### Status indicators

| State | Classes |
|-------|---------|
| Resolved/healthy | `badge badge-sm badge-success` |
| Not found/warning | `badge badge-sm badge-warning` |

### Consequences

* Good, because every badge follows a predictable pattern — no per-instance decisions
* Good, because semantic colors reinforce meaning at a glance
* Neutral, because `badge-sm` is the only size used; if a larger badge is needed, revisit
