---
status: accepted
date: 2026-04-07
---
# Stat card as shared component

## Context and Problem Statement

The dashboard displays numeric summaries (Watcher status, Matches count, Drafts count, Cards count, Raw Events, Domain Events, Errors) using a private `stat_card/1` function component defined inside `DashboardLive`. This component is the primary numeric summary pattern in the application and is likely to be reused on match detail, draft detail, and future analytics pages.

## Decision Outcome

Extract `stat_card/1` from `DashboardLive` into `Scry2Web.CoreComponents` as a public function component.

Public API:
```elixir
attr :title, :string, required: true
attr :value, :any, required: true
attr :class, :string, default: ""
```

The component renders a `bg-base-200` card with a muted uppercase title and a large value. The optional `:class` attribute allows per-instance styling (e.g., `text-error` for error counts).

### Consequences

* Good, because any LiveView can display stat summaries without duplicating markup
* Good, because the card style is consistent across the application
* Neutral, because the component is intentionally minimal — richer variants (icons, sparklines) can be added later without breaking existing usage
