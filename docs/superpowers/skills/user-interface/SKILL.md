---
name: user-interface
description: "Use this skill before any UI work — LiveView templates, components, CSS, styling, layout, modals, cards, badges, buttons, themes, or visual design. Contains all component recipes, styling conventions, and design principles for Scry2."
---

## Design Values

- **Readability first.** Every visual choice serves readability above aesthetics.
- **Color is signal.** Calm when healthy, color draws attention to problems.
- **Dark-first, light-right.** Cool slate grays. Both themes genuinely good.
- **System fonts.** Monospace only for functional alignment (arena IDs, mana values, event types, timestamps).
- **Cards for grouping.** Scannable, self-contained sections using daisyUI `bg-base-200` cards.
- **Live data feels alive.** Real-time PubSub updates, debounced to prevent query storms (ADR-023).
- **Inspiration:** Linear.app — clean, fast, focused, excellent dark mode.

## Theme System

Two themes via daisyUI plugin in `assets/css/app.css`. Colors use oklch color space.

**Always use theme variables** — never hardcode oklch for themeable colors:
- Tailwind: `text-base-content/60`, `bg-primary/10`
- CSS: `oklch(from var(--color-base-content) l c h / 0.6)`
- Exception: achromatic overlays (`oklch(0% 0 0 / 0.7)`)

**Semantic colors for MTG analytics:**

| Role | Usage |
|------|-------|
| Primary (blue/orange) | Interactive elements, focus rings, accents |
| Success (green) | Wins, watcher running, healthy status |
| Warning (amber) | Attention states, path not found, risky actions |
| Error (red) | Losses, processing errors, watcher stopped |
| Info (blue) | Informational badges, draft/card metadata |
| Base content | Text hierarchy via opacity (`/60`, `/40`, `/20`) |

## Component Recipes

### Buttons ([UIDR-002])

| Context | Recipe |
|---------|--------|
| **Action** (refresh, search, import) | `btn btn-soft btn-primary` |
| **Primary CTA** (single dominant per view) | `btn btn-primary` |
| **Dangerous** (clear data, delete) | `btn btn-soft btn-error` |
| **Risky** (re-ingest, reset) | `btn btn-soft btn-warning` |
| **Dismiss/cancel** | `btn btn-ghost` |

**Never** use solid-fill semantic buttons without `btn-soft`. At most one `btn-primary` per view.

### Badges ([UIDR-001])

| Context | Recipe |
|---------|--------|
| **Win** | `badge badge-sm badge-success` |
| **Loss** | `badge badge-sm badge-error` |
| **Pending/unknown** | `badge badge-sm badge-ghost` |
| **Mythic** | `badge badge-sm badge-warning` |
| **Rare** | `badge badge-sm badge-accent` |
| **Uncommon** | `badge badge-sm badge-info` |
| **Common** | `badge badge-sm badge-ghost` |
| **Status healthy** | `badge badge-sm badge-success` |
| **Status warning** | `badge badge-sm badge-warning` |

### Stat Cards ([UIDR-003])

```heex
<.stat_card title="Matches" value={@counts.matches} />
<.stat_card title="Errors" value={@counts.errors} class="text-error" />
```

Shared component in `CoreComponents`. Renders `bg-base-200` card with muted uppercase title and large value.

### Section Headers

```heex
<h1 class="text-2xl font-semibold">Page Title</h1>
<h2 class="text-lg font-semibold mb-2">Section Title</h2>
```

### Empty States

```heex
<.empty_state>
  No matches recorded yet. Play a game with MTGA detailed logs enabled.
</.empty_state>
```

Shared component in `CoreComponents`. Centered muted message with icon.

### Back Links

```heex
<.back_link navigate={~p"/matches"} label="All matches" />
```

Shared component in `CoreComponents`. Renders `← label` as a link.

### Icons

```heex
<.icon name="hero-chevron-right-mini" class="size-4" />
```

Sizes: `size-3` (12px), `size-4` (16px default), `size-5` (20px), `size-6` (24px).

## Layout Components

| Component | File | Purpose |
|-----------|------|---------|
| `app/1` | `layouts.ex` | Root layout: horizontal navbar + content area |
| `console_mount/1` | `layouts.ex` | Sticky Guake-style console drawer |
| `flash_group/1` | `layouts.ex` | Toast notifications |
| `player_selector/1` | `layouts.ex` | Player filter dropdown (always visible) |
| `theme_toggle/1` | `layouts.ex` | System/Light/Dark picker |

## CSS Animation Rules

Per CLAUDE.md — these are non-negotiable for LiveView performance:

- **Only animate `opacity` and `transform`** — compositor-only, GPU-cheap
- **Never use CSS keyframe animations on LiveView stream items** — morphdom replays them. Use `phx-mounted` + `JS.transition()` instead
- **Minimize `reset_stream` calls** — only reset when grid-affecting params change
- **`backdrop-filter` elements must stay in DOM** — never `:if={}`. Toggle via `data-state` + `visibility: hidden`
- **Never animate** `background`, `backdrop-filter`, `box-shadow`, or layout properties on blur elements

## Anti-Patterns

- Solid-fill semantic buttons (`btn-error` without `btn-soft`)
- Hardcoded oklch color values for themeable colors
- `:if={}` on elements with `backdrop-filter`
- CSS keyframe animations on LiveView stream items
- Monospace font for aesthetic reasons (only for arena IDs, timestamps, event types, mana values)
- Inline logic in LiveView templates (per ADR-013 — extract to helpers)
- Bare `list_*` calls without current filter state in `handle_info` (per ADR-023)

## Component Inventory

| Component | File | Purpose |
|-----------|------|---------|
| `flash/1` | `core_components.ex` | Toast notifications |
| `button/1` | `core_components.ex` | Links and buttons (default: soft primary) |
| `input/1` | `core_components.ex` | Form fields with label + errors |
| `header/1` | `core_components.ex` | Page title bar with actions slot |
| `table/1` | `core_components.ex` | Zebra-striped data tables |
| `list/1` | `core_components.ex` | Key-value display list |
| `icon/1` | `core_components.ex` | Heroicon rendering |
| `stat_card/1` | `core_components.ex` | Numeric summary card |
| `empty_state/1` | `core_components.ex` | "No data" placeholder |
| `back_link/1` | `core_components.ex` | Navigation back link |
| `result_badge/1` | `core_components.ex` | Win/loss badge |
| `rarity_badge/1` | `core_components.ex` | Card rarity badge |
| `app/1` | `layouts.ex` | Root layout (navbar + content) |
| `console_mount/1` | `layouts.ex` | Sticky console drawer mount |
| `player_selector/1` | `layouts.ex` | Player filter dropdown |
| `theme_toggle/1` | `layouts.ex` | Theme picker |
| `chip_row/1` | `console_components.ex` | Console filter chips |
| `log_list/1` | `console_components.ex` | Monospace log stream |
| `action_footer/1` | `console_components.ex` | Console controls |

## Page Structure

| Page | Path | Role |
|------|------|------|
| **Dashboard** | `/` | Watcher status, stat cards, event counts, errors |
| **Matches** | `/matches`, `/matches/:id` | Match list + detail (dual render) |
| **Drafts** | `/drafts`, `/drafts/:id` | Draft list + detail (dual render) |
| **Cards** | `/cards` | Filterable card database |
| **Settings** | `/settings` | Config snapshot, log file status |
| **Console** | `/console` | Full-page log viewer |
| **Console (drawer)** | sticky | Guake-style overlay (`` ` `` toggle) |

## Decision Records

All UI decisions live in `decisions/user-interface/` using MADR 4.0 format.

| UIDR | Decision |
|------|----------|
| 001 | Badges: solid-fill `badge-sm` with semantic color per category |
| 002 | Buttons: `btn-soft` default, one `btn-primary` CTA per view, never solid semantic |
| 003 | Stat card: shared `CoreComponents.stat_card/1` with title + value + optional class |
