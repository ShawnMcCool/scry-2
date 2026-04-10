# Direction A — Reasoning

## Style Description

Compact, information-dense dark interface using the daisyUI "night" theme. The visual language is drawn from both MTG's own dark UI conventions (Arena's dark-panel aesthetic) and professional tool UIs (VS Code, Linear, Raycast). Every element earns its pixels — no decorative chrome, no padding theater.

The palette leans into near-black backgrounds with blue-gray text, using color only for semantic signal: mana colors are the canonical MTG hues, rarity indicators use the established MTG convention (amber mythic, purple rare, cyan uncommon, gray common), and interactive highlights use sky-blue as the primary accent.

## Design Decisions

### Search Bar Row

The search input is a dark pill shape with a hairline border that brightens on focus — subtle enough not to dominate, obvious enough to invite interaction. The × clear button appears inside the input to avoid layout shift.

Mana toggle circles are 32px — large enough to hit comfortably, small enough to sit inline with the search bar without the row feeling heavy. Active state uses a ring rather than fill change so the underlying mana color stays legible. Two mana colors (U, R) are shown active to demonstrate the combined filter state.

The filter icon (≡ funnel-style) sits at the far right, visually grouped away from mana toggles to signal a different kind of filtering (structured facets vs. quick color filters).

### Results Header

Kept intentionally dim and small (text-xs, muted color). It's a status line, not a heading — it confirms what the user already knows (search is active) rather than competing with the grid content.

### Card Grid

`auto-fill` with `minmax(108px, 1fr)` produces 7-8 columns on a wide screen without any media query breakpoints. The 5:7 aspect ratio matches real MTG card proportions. Each placeholder uses a unique dark gradient with a subtle radial glow suggesting card art without being distracting.

Card names truncate with ellipsis — the grid is a browsing surface, not a reading surface. Rarity is shown as a ◆ symbol with a single letter (M/R/U/C) to stay compact while remaining scannable.

Hover state lifts the card 2px with a faint blue glow on the art — communicates interactivity without being flashy.

### Bottom Panels — Data Sources

The progress bars use the mana-color palette (17lands=blue, Scryfall=purple, images=cyan) to give each source a consistent visual identity across the app. Bars are intentionally subtle (50% opacity) so they read as decorative context, not action items.

The summary line uses a two-column layout that mimics a receipt — key=value pairs at either end. No heading needed because the panel title already establishes context.

### Bottom Panels — Import Controls

Each import source row is a horizontal flex: name+timestamp (flex-grow), refresh button (flex-shrink), status dot (fixed). This keeps the action affordance close to the source it controls without needing labels.

The status dot for the running Scryfall job uses an orange glow — warmer than the idle green, less alarming than red. The Oban queue summary at the bottom consolidates state across all jobs into one line.

The hover color for the Scryfall Refresh button is orange (matching its "running" dot) rather than blue — a subtle way to hint that triggering a refresh on a running job behaves differently.

### Filter Drawer

Positioned as a fixed panel at `right: -280px` on a 360px-wide drawer, exposing ~80px of the left edge. This "20% revealed" treatment signals the panel's existence without requiring an open state in the mockup, and gives the user a target to grab/click.

The peek is intentional UX: users don't need to know the filter button exists if the drawer edge is always subtly visible at the screen edge.

Rarity uses the same ◆ icon system as the grid for visual consistency — the filter controls feel like they belong to the same design language as the content. Mana Value pills use the same dark-pill style as the potential "active search tokens" idiom the app might eventually use.

A bonus Card Type section was added to show the drawer has scrollable depth — important for communicating that the filter panel is a full-featured facet browser, not just two options.

## Requirements Mapping

| Requirement | Implementation |
|---|---|
| Dark theme, daisyUI tokens | `data-theme="night"`, explicit token usage throughout |
| Mana symbol circles, MTG-colored | 32px circles, W/U/B/R/G/M/C with canonical MTG palette |
| Active color filter state | U and R shown active with `ring-2 ring-primary` via `.active` class |
| Search input, pill shape, clear button | `.search-input` with border-radius 9999px, `×` button inside |
| Filter icon button at far right | SVG funnel icon, consistent dark border style |
| Results header with count | Dim small text, "Showing N of N" |
| ~7-8 column responsive card grid | `auto-fill minmax(108px, 1fr)` |
| 5:7 card art proportions | `aspect-ratio: 5/7` on `.card-art` |
| Subtle gradient placeholders | Unique dark radial gradients per card, fire/ice/nature themes |
| Rarity badges | ◆ symbol + single letter, amber/purple/cyan/gray |
| Data Sources panel with progress bars | Hairline bars (3px), per-source color, records + size labels |
| Import Controls panel with refresh + status | Outline refresh buttons, colored status dots, Oban summary line |
| Filter drawer 20% revealed | Fixed position at right:-280px on 360px drawer = ~80px peek |
| Rarity checkboxes, MV pills in drawer | ◆ icons for rarity, pill buttons with active state |

## Trade-offs

**Gains:**
- Maximum card density — the grid gets the most vertical space
- All key controls accessible in a single horizontal row (no tab switching)
- Filter drawer doesn't consume permanent layout space
- Status panels are compact without feeling cramped

**Sacrifices:**
- No set/expansion filter visible in this direction (would be in the full drawer)
- No sort controls in this layout (could be added to the results header row)
- Card names at 0.72rem are small — a larger minimum card size would help legibility but reduce density
- The drawer peek is only a visual hint; without JavaScript the drawer doesn't animate open in this static mockup
