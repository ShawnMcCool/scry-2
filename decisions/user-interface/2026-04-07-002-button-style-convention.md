---
status: accepted
date: 2026-04-07
---
# Button style convention

## Context and Problem Statement

Scry2 uses buttons in the dashboard ("Refresh cards"), navigation links, and will gain more interactive controls as analytics features grow. Without a convention, button styling becomes inconsistent.

## Decision Outcome

Buttons follow a hierarchy based on visual weight. The `btn-soft` variant is the default for action buttons — it provides sufficient contrast without dominating the page.

| Context | Classes | Example |
|---------|---------|---------|
| **Action** (refresh, search, import) | `btn btn-soft btn-primary` | Refresh cards from 17lands |
| **Primary CTA** (single dominant per view) | `btn btn-primary` | — |
| **Dangerous** (clear data, delete) | `btn btn-soft btn-error` | Clear all events |
| **Risky** (re-ingest, reset) | `btn btn-soft btn-warning` | Re-ingest all events |
| **Dismiss/cancel** (close, cancel) | `btn btn-ghost` | Cancel |

**Rules:**
- Never use solid-fill semantic buttons (`btn-error`, `btn-success`) without `btn-soft`. Solid-fill text washes out against the base background.
- At most one `btn-primary` (solid) per view. All other actions use `btn-soft`.
- Size modifiers (`btn-sm`, `btn-xs`) are optional and determined by context.

### Consequences

* Good, because visual weight communicates action importance
* Good, because `btn-soft` default keeps the interface calm
* Good, because the convention scales to new pages without per-button decisions
