---
status: accepted
date: 2026-04-11
supersedes: 2026-04-07-001-badge-style-convention.md
---
# No solid-fill semantic backgrounds

## Context and Problem Statement

Scry2's dark theme used solid-fill daisyUI semantic variants — `alert-warning`, `badge-success`, `alert-error`, etc. — for status surfaces on the Health page, Operations page, Settings page, Setup tour, match/card badges, and flash toasts. Against the slate dark background these saturated fills read as "insanely bright" and dominate every screen they appear on. A green "OK" pill on a healthy check competed for attention with a full-width yellow "Some checks need attention" banner — the visual volume was identical regardless of whether the user needed to act.

This violates the first principle of the project's design language: *readability first; color is signal; calm when healthy, color draws attention to problems*. When every status is loud, nothing is.

UIDR-001 previously codified the solid-fill convention for badges and is superseded by this decision.

## Decision Outcome

**Semantic colors never fill the background of a text-bearing surface at full saturation.** Use daisyUI's `-soft` modifier, or opacity-modified tints (`bg-warning/10`, `bg-error/20`), so color signals without dominating.

### Component recipes

| Component | Before | After |
|---|---|---|
| Alerts (banners, inline sections, flash toasts) | `alert alert-warning` | `alert alert-soft alert-warning` |
| Badges (status, result, rarity, label) | `badge badge-sm badge-success` | `badge badge-sm badge-soft badge-success` |
| Container backgrounds | `bg-warning`, `bg-success`, ... | `bg-warning/10` (or `/15`, `/20`) |

### Banned without a softening modifier

- `alert-success`, `alert-warning`, `alert-error`, `alert-info` — must be paired with `alert-soft`
- `badge-success`, `badge-warning`, `badge-error`, `badge-info`, `badge-accent` — must be paired with `badge-soft`
- Raw `bg-warning`, `bg-success`, `bg-error`, `bg-info`, `bg-primary` on any text-bearing or container-sized element — must use an opacity suffix (`/10`, `/15`, `/20`)

### Exceptions

- **Icons as foreground.** `text-success`, `text-warning`, `text-error` on `<.icon>` elements are foreground glyphs, not fills — they stay at full saturation.
- **Small indicator dots.** `size-2` / `size-3` solid-color circles (Oban status dot, setup progress dots) are the indicator itself, not a container. Left as-is.
- **Interactive primary CTA.** `btn btn-primary` (at most one per view per UIDR-002) is an action surface, not a semantic status highlight, and is unaffected. All other semantic buttons already require `btn-soft` (UIDR-002).

### Why `-soft` and not just `/10` tints everywhere

daisyUI's soft variant produces a themed low-saturation fill with a subtly tinted foreground — it reads as "healthy" / "attention" / "error" without shouting, and adapts cleanly to both light and dark themes. Hand-rolled `/10` tints work for ad-hoc surfaces but drift from the component system for first-class badges and alerts, so `-soft` is the canonical form for those components.

## Consequences

- **Good**, because the visual volume of the UI finally matches the semantic weight of the state — healthy checks recede, attention-worthy ones still stand out by contrast.
- **Good**, because the rule is uniform across every status surface (alerts, badges, toasts, match results, card rarity). No per-instance design decisions.
- **Good**, because the rule is mechanically checkable — a grep for `\balert-(success|warning|error|info)\b` without `alert-soft` on the same element is a reliable regression check.
- **Neutral**, because win/loss and rarity badges lose some saturation. Mitigated by the soft variant still being semantically colored and by the fact that match/card layouts already convey win/loss through position, text, and score.
- **Bad**, because UIDR-001 is superseded after only four days of service. Mitigated by the fact that the rule was wrong from the start — the solid fills were never reviewed against the dark theme in aggregate.
