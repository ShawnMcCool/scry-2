---
status: accepted
date: 2026-04-07
---
# Show don't hide — display card data inline

## Context and Problem Statement

The natural instinct when building data-heavy pages (mulligans, deck lists, draft picks) is to show compact summary rows that the user clicks to expand. This hides the most interesting data — the actual cards — behind an interaction barrier. In a card game analytics app, the cards ARE the data. Forcing users to click into each mulligan row to see what was in their hand defeats the purpose.

## Decision Outcome

Always show card data inline. Never hide card images or hand contents behind expandable rows or click-to-reveal patterns.

Concrete example — mulligan rows: each row displays the cards that were in hand as small card images, alongside an orange-bordered "Keep" or blue-bordered "Mulligan" badge. The user sees the hand composition at a glance without clicking anything.

This principle applies broadly:
- **Mulligan history** — show the hand's cards directly in each row
- **Deck lists** — show card images, not just text names
- **Draft picks** — show the picked card and the pack contents visually
- **Match summaries** — show deck archetypes with representative card art

When a page would load too many images, solve it with the image cache batch API (ADR-024) rather than hiding the images.

### Consequences

* Good, because users see the data they care about immediately
* Good, because browsing history becomes visual pattern recognition rather than reading text
* Good, because it leverages the rich card art that makes Magic visually distinctive
* Neutral, because pages load more images per view — mitigated by the centralized image cache (ADR-024)
