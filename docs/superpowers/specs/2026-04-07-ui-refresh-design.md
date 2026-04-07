# UI Refresh — Dark Theme, DPI Scaling, Larger Cards, Hover Detail

## Problem

The current UI has an orange/purple "halloween" palette, fixed pixel sizing that doesn't scale with display DPI, small card images on the mulligans page, and no way to see card detail without navigating away.

## Solution

### 1. Dark Only Theme — Cool Slate

Remove the light theme and theme toggle. Single dark theme:

- **Base:** `#1a1d23` (cool slate, slight blue tint)
- **Surface:** `#21252b` for raised elements (cards, rows)
- **Border:** `rgba(255,255,255,0.06)` — nearly invisible
- **Text primary:** `#e2e8f0` (slate white)
- **Text secondary:** `rgba(255,255,255,0.4)`
- **Text muted:** `rgba(255,255,255,0.25)`
- **Accent/links:** `#818cf8` (soft indigo)
- **Success/kept:** `#4ade80` (green)
- **Mulligan badge:** `#94a3b8` (neutral slate) at reduced opacity
- **Error:** `#f87171` (red)
- **Warning:** `#fbbf24` (amber)

Remove: theme toggle component, `localStorage` theme switching, light theme CSS, `@custom-variant dark`.

### 2. Responsive DPI Scaling

Add `clamp()` root font size so the entire UI scales with viewport:

```css
html { font-size: clamp(14px, 0.95vw + 4px, 18px); }
```

All component sizing uses `rem` — scales automatically. Card images use rem-based widths instead of fixed `w-12`/`w-20` pixel classes.

### 3. Mulligan Page — Larger Cards, Flat Rows

- Card images: `w-[4.5rem]` (72px default, scales with DPI)
- No left border accent on rows — badge carries the decision
- No row background — flat on the page background
- Mulliganed hands dimmed to `opacity-45`
- "Kept" badge: green pill. "Mull" badge: grey pill
- Pill badges use `rounded-full` (fully rounded)
- Remove `decision_border_class/1` helper (no longer used)

### 4. Hover Card Detail Popup

A JS hook on `<.card_image>` that shows a large card preview near the cursor:

- **Shared popup element** — single `<div id="card-hover-popup">` in the root layout, repositioned on hover (not one per card)
- **Hook name:** `CardHover` — attached via `phx-hook="CardHover"` on each card image
- **Behavior:**
  - `mouseenter`: show popup with larger image (same cached URL), position near cursor
  - `mousemove`: reposition popup to follow cursor with offset
  - `mouseleave`: hide popup
- **Sizing:** popup card image ~250px wide
- **Position:** offset 20px right and 20px below cursor, clamped to viewport edges
- **Pure client-side** — no server round-trip, image already in browser cache

### Files

| File | Action | Change |
|------|--------|--------|
| `assets/css/app.css` | Modify | Replace dual themes with single dark, add clamp() root font, remove theme toggle CSS |
| `lib/scry_2_web/components/layouts/root.html.heex` | Modify | Hardcode `data-theme="dark"`, remove theme JS, add popup div |
| `lib/scry_2_web/components/layouts.ex` | Modify | Remove theme toggle component |
| `lib/scry_2_web/components/card_components.ex` | Modify | Add `phx-hook="CardHover"`, update default card size to rem |
| `assets/js/app.js` | Modify | Add `CardHover` hook |
| `lib/scry_2_web/live/mulligans_live.ex` | Modify | Update card size, remove border class, flat rows, dim mulligans |
| `lib/scry_2_web/live/mulligans_helpers.ex` | Modify | Update badge classes (green pill, grey pill), remove border helper |
| `test/scry_2_web/live/mulligans_helpers_test.exs` | Modify | Update badge class assertions, remove border class tests |
| `assets/vendor/daisyui-theme.js` | Modify | Single dark theme definition |
