---
status: accepted
date: 2026-04-09
---
# ECharts layout conventions for stacked chart groups

## Context and Problem Statement

When multiple ECharts charts are stacked vertically in a section (e.g. a climb chart above a momentum chart), each chart computes its own grid independently. Charts with longer Y-axis labels (e.g. rank class names: "Diamond", "Platinum") need a wider left margin than charts with short numeric labels (e.g. "30", "5"). This causes the plot areas to start at different X positions, making the X-axes visually misaligned even when they share the same time domain.

## Decision

All charts in the same visual group must share identical `grid` configuration so their plot areas are perfectly aligned:

```js
grid: {left: 80, right: 20, top: 16, bottom: 40}
```

- **`left: 80`** — sized to accommodate the widest Y-axis label in any chart in the group (rank class names like "Diamond"). Numeric-only charts must use this same value even though they need less space.
- **`right: 20`** — consistent right padding.
- **`top: 16`** — minimal top padding (no title inside the chart area).
- **`bottom: 40`** — room for X-axis labels.

## Consequences

- All chart plot areas in a group start and end at the same pixel column, so X-axes visually align.
- The wider left margin on numeric-only charts wastes a small amount of horizontal space, but the alignment is worth it.
- When adding a new chart type to a group, check whether its Y-axis labels are wider than "Diamond" (9 chars). If so, update the shared `left` value across all charts in the group.

## Additional ECharts conventions

- **Theme**: initialise with `echarts.init(el, null, {renderer: 'canvas'})` — no built-in theme. Colours are set explicitly per series to match the daisyUI dark palette.
- **Background**: always `backgroundColor: "transparent"` so the chart sits inside the daisyUI `bg-base-200` container.
- **Grid lines**: `splitLine: {lineStyle: {color: "#1f2937"}}` on value axes; disabled on time axes.
- **Axis lines/labels**: `color: "#9ca3af"` for labels, `color: "#374151"` for axis lines — matches `base-content/40` and `base-300` in the dark theme.
- **Update without reinit**: call `chart.setOption(newOption, {notMerge: false})` in the hook's `updated()` callback. Never dispose and reinitialise on data change — it causes visible flicker.
- **Responsive sizing**: attach a `ResizeObserver` in `mounted()` that calls `chart.resize()`. Disconnect it in `destroyed()`.
- **Container height**: ECharts requires an explicit height. Use `style="height: Npx"` on the hook element — Tailwind height classes alone are not reliable because the canvas is sized at init time.
