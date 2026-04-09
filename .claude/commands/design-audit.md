---
description: Systematic design audit — UI convention compliance, UIDR adherence, UX state coverage, and aspirational gap analysis.
argument-hint: "[page-or-component (optional)]"
allowed-tools: Read, Glob, Grep, Bash(mix compile *), mcp__chrome-devtools__list_pages, mcp__chrome-devtools__new_page, mcp__chrome-devtools__navigate_page, mcp__chrome-devtools__take_screenshot, mcp__chrome-devtools__list_console_messages, mcp__chrome-devtools__lighthouse_audit, mcp__chrome-devtools__evaluate_script, mcp__chrome-devtools__take_snapshot
---

# Design Audit

You are performing a meticulous design audit of the Scry 2 UI.
Your goal is to find **concrete, evidence-based** design-convention, UIDR-compliance,
and UX-coverage issues — not speculative polish suggestions. Every finding must
cite the exact file and line, quote the offending snippet, and propose a
specific fix.

**Brutal honesty is mandatory.** Do not soften findings, hedge with qualifiers,
or balance criticism with unearned praise. If the implementation drifts from
documented conventions, violates a UIDR, or ships a page without an empty state,
say so directly. A sycophantic audit is worse than no audit at all.

**Scope:** If `$ARGUMENTS` is provided, focus on that page, component, or file.
Otherwise, audit the full Phoenix LiveView UI under `lib/scry_2_web/`.

**Strict lane.** This audit deliberately does NOT cover:

- **CSS/LiveView perf anti-patterns** (stream-item keyframes, conditional
  `backdrop-filter`, `reset_stream` overuse) — belongs to `/performance-audit`
- **Docs out of sync with code** — belongs to `/docs-audit`
- **Dead code, unused styles, duplication in logic** — belongs to
  `/engineering-audit`

If a finding clearly belongs in a sibling lane, **skip it**.

**The cardinal rule: read the source.** Every design claim you verify must be
checked against actual component/LiveView files. Authority sources are
`CLAUDE.md` (UI Design section, CSS Animation Rules, LiveView Callbacks),
`assets/css/app.css` (theme tokens), and all files under
`decisions/user-interface/`.

---

## Phase 1 — Orientation

Load the authority layer before analysis.

1. Read the **UI Design**, **CSS Animation Rules**, and **LiveView Callbacks**
   sections of `CLAUDE.md` in full.
2. Read every file in `decisions/user-interface/` (glob `*.md`, skip `template.md`
   if present). These are the UIDRs — the binding style decisions for this project.
3. Read `assets/css/app.css` — note the custom daisyUI theme block and the token
   names so Pass 3 can distinguish legitimate theme token uses from hardcoded values.
4. Glob `lib/scry_2_web/components/*.ex` and `lib/scry_2_web/live/*.ex` to build
   the target inventory.
5. Read `lib/scry_2_web/router.ex` — extract the list of `live "/path"` routes for
   Pass 4's orphan check.

---

## Phase 2 — Analysis Passes

Work through each pass sequentially. For each pass, explore the relevant code
thoroughly. Do not guess — read the actual source and quote what you find.

### Pass 1 — CSS Animation & DOM rules (from CLAUDE.md)

Audit implementation against the documented CSS rules:

1. **No keyframe animation on stream items** — grep for `animation:` or
   `@keyframes` applied to elements that are LiveView stream items. The rule:
   use `phx-mounted` + `JS.transition()` instead. Each violation → **Critical**
   (causes visible flash on stream reset).

2. **Minimize `reset_stream` calls** — in `handle_params`, look for unconditional
   `reset_stream` calls that run on every params change, including selection-only
   changes (modal open/close, row highlight). Each unconditional reset that could
   be conditional → **Moderate**.

3. **`backdrop-filter` elements must stay in DOM** — grep for
   `backdrop-filter` or `backdrop-blur` in `.ex` and `.css` files. Any element
   using `backdrop-filter` that is conditionally rendered with `:if={}` rather
   than toggled with `data-state` + visibility/pointer-events →  **Moderate**.

4. **Only animate `opacity` and `transform`** — grep for CSS `transition:` or
   `JS.transition()` calls that include `background`, `backdrop-filter`,
   `box-shadow`, or layout properties. Each violation → **Moderate** (per-frame
   recompositing cost).

### Pass 2 — LiveView callback conventions (from CLAUDE.md)

1. **`@impl true` before every callback group** — grep each LiveView for
   `def mount`, `def render`, `def handle_event`, `def handle_info`,
   `def handle_params`. Each that lacks a preceding `@impl true` on the same
   function name's first clause → **Minor**.

2. **`handle_params` mount-vs-selection distinction** — for LiveViews that
   handle both initial load and URL-param changes (e.g. `?selected=X`), check
   whether `handle_params` distinguishes nil→X (initial load) from Y→X
   (user navigation). Resetting state on initial load when the URL already
   carries params can cause flickers or lost state → **Moderate** if missing.

### Pass 3 — UIDR compliance (mechanical)

For each UIDR file found in `decisions/user-interface/`, run a concrete
grep-based violation scan. Each violation is a separate finding.

#### UIDR-001 — Badge style convention

**Rule:** (read the full UIDR before scanning)
Solid-fill daisyUI badges (`badge-sm`) with semantic color per category:
win/loss uses success/error/ghost; rarity uses warning/accent/info/ghost;
status uses success/warning.

**Scan:**
- Grep for `badge` in `lib/scry_2_web/` `.ex` files.
- For each hit, verify it uses `badge-sm` and the correct semantic color for
  its category.
- Wrong semantic color for a known category (e.g. `badge-primary` for win/loss)
  → **Moderate**
- Missing `badge-sm` size modifier → **Minor**
- Inline `style=` color override on a badge → **Moderate**

#### UIDR-002 — Button style convention

**Rule:** (read the full UIDR before scanning)
`btn-soft` is the default for action buttons. Destructive/risky actions use
`btn-soft btn-error` / `btn-soft btn-warning`. Dismiss/cancel uses `btn-ghost`.
Solid-fill (`btn-primary`) reserved for at most one dominant CTA per view.

**Scan:**
- Grep for `btn-error`, `btn-success`, `btn-warning`, `btn-info` in `.ex` files.
- Any solid-fill semantic button (no `btn-soft` paired) → **Moderate**
- More than one `btn-primary` (solid, no `btn-soft`) on a single page → **Minor**
- Destructive/risky action not using the correct semantic color (e.g. delete
  with `btn-soft btn-primary`) → **Moderate**

#### UIDR-003 — Stat card as shared component

**Rule:** (read the full UIDR before scanning)
`stat_card/1` is defined in `Scry2Web.CoreComponents` as a public function
component. All pages use it for numeric summaries — no inline duplicates.

**Scan:**
- Grep for `stat_card` in `lib/scry_2_web/components/core_components.ex` —
  verify it exists as a public component.
- Grep for inline card markup in LiveView files that renders a `bg-base-200`
  card with a muted title and a large value. Each inline duplicate that should
  use `<.stat_card>` → **Moderate**

#### UIDR-004 — Show don't hide

**Rule:** (read the full UIDR before scanning)
Card data (images, hand contents) is always shown inline — never hidden behind
expandable rows or click-to-reveal patterns. Pages that would load many images
solve it with the image cache API, not by hiding images.

**Scan:**
- For pages that show game/draft data (mulligans, drafts, matches, events):
  grep for `details`/`summary` HTML elements used to collapse card data
  → **Moderate** (click-to-reveal pattern)
- Grep for `:if={}` conditions that hide card images or hand contents behind
  a boolean flag that requires user interaction → **Moderate**
- Text-only representations of card data (name string without image) where the
  image could be shown inline → **Minor**

### Pass 4 — UX state coverage & flow gaps

For each LiveView in `lib/scry_2_web/live/` (dashboard, stats, ranks, economy,
matches, cards, drafts, events, mulligans, settings, operations, console), check:

- **Empty state** — what does the page render when there is no data? Search for
  `:if={}` or `cond do` branches handling empty collections. A page that renders
  nothing (blank area, no message) when empty → **Critical**. A page that renders
  a minimal "no results" without an affordance to populate it → **Moderate**.

- **Loading state** — for operations that take longer than ~100ms (database
  fetches, API calls), is there a skeleton, spinner, or `phx-loading-*` transition?
  Missing loading feedback on a slow path → **Moderate**.

- **Error state** — `assign_async` branches, `handle_info` failure messages.
  Pages that silently swallow errors → **Critical**.

- **Destructive confirmations** — grep `handle_event` callbacks for verbs like
  `"delete"`, `"clear"`, `"abandon"`, `"discard"`, `"overwrite"`, `"reset"`,
  `"reingest"`. Each destructive handler must be gated by a confirmation dialog
  or `phx-confirm`. Unguarded destructive actions → **Critical**.

- **Orphan pages** — cross-reference the router's `live "/path"` routes against
  LiveView modules in `lib/scry_2_web/live/`. Also check the nav links in
  `lib/scry_2_web/components/layouts.ex`. A LiveView registered in the router
  but not linked from nav or any in-page affordance → **Moderate**.

### Pass 5 — Aspirational gap analysis

Scan `decisions/user-interface/` for "planned", "future", or "todo" markers
in any UIDR. For each entry:

1. Determine whether the feature is implemented (search for evidence in components
   and LiveViews).
2. If implemented, skip.
3. If partially implemented, flag as **Moderate** with what's missing.
4. If not implemented, flag as **Moderate** with the UIDR location and description.

Also check `decisions/architecture/` for ADRs with implementation status markers
that indicate a feature is not yet complete.

### Pass 6 — Live visual inspection (opportunistic)

This pass is **optional and runs only if** chrome-devtools MCP is available
**and** the dev server is reachable at `http://127.0.0.1:4002`.

**Availability probe.** Attempt `mcp__chrome-devtools__list_pages`. If the
tool is unavailable or the call fails, skip the entire pass and record a single
note in the final summary: *"Pass 6 skipped: dev server not reachable at
127.0.0.1:4002"*. Never error out; never block the static passes.

**If available, run the following against each top-level page**
(`/`, `/matches`, `/drafts`, `/cards`, `/events`, `/stats`, `/mulligans`,
`/settings`, `/operations`, `/console`):

1. **Navigate and screenshot.** `navigate_page` to the route, wait for the page
   to settle, `take_screenshot`. Use the screenshot as narrative evidence.
2. **Console cleanliness.** `list_console_messages` — any error → **Critical**,
   any warning → **Moderate**. Quote the message text.
3. **Accessibility baseline.** `lighthouse_audit` with only the `accessibility`
   category. Flag every individual audit that fails. Severity = **Critical** for
   blockers (`color-contrast`, `image-alt`, `label`, `button-name`, `link-name`),
   **Moderate** for others.
4. **Rendered contrast spot-check.** For each page, use `evaluate_script`:
   ```js
   const el = document.querySelector('h1, .text-base-content, p');
   const s = getComputedStyle(el);
   return { color: s.color, background: getComputedStyle(document.body).backgroundColor };
   ```
   Compute WCAG contrast ratio and flag anything below 4.5:1 for normal text
   or 3:1 for large text. **Critical** for body text, **Moderate** for decorative.

---

## Phase 3 — Severity Classification

| Severity | Criteria |
|----------|----------|
| **Critical** | User-visible design bug, accessibility blocker, missing required state (blank page when empty), console error on clean load, unguarded destructive action |
| **Moderate** | Inconsistency that degrades polish, UIDR violation, aspirational gap, missing loading/error state, orphan LiveView |
| **Minor** | Cosmetic deviation, single missing size modifier, single `@impl true` gap |

---

## Phase 4 — Output Format

Present findings **grouped by pass**, sorted **Critical → Moderate → Minor**
within each pass. For each finding:

1. **Location** — exact `file_path:line_number` (or `page_path` for Pass 6)
2. **Issue** — one-sentence description
3. **Evidence** — quoted snippet or grep result
4. **Severity** — Critical / Moderate / Minor
5. **Fix** — concrete, specific change

At the end, provide a **summary** with:

- **Findings per pass** — count per pass, broken down by severity
- **Top 5 cross-cutting improvements** — patterns that appear in 3+ places or
  that would have the highest overall impact on UI health
- **Overall design health assessment** — one paragraph synthesizing the findings
- **Pass 6 status** — a single line recording whether Pass 6 ran, and if
  skipped, why

---

## Rules

- **Evidence, not speculation.** Grep result, file:line, and a quoted snippet are
  required. "This *might* look wrong" is not a finding.
- **Stay in the lane.** Engineering, performance, and docs findings belong in the
  sibling audits. Skip them here.
- **Cite every finding.** Every issue must include the exact file path and line.
- **Skip what's fine.** If a pass has no issues, say "No issues found."
- **No unearned praise.** One sentence for clean areas. Spend words on problems.
- **No modifications.** Analysis only — do not edit or create any files.
- **Scope to arguments.** If `$ARGUMENTS` names a specific page or component,
  analyze only that area. No arg → full audit (Passes 1–5, plus Pass 6 if available).
- **Pass 6 graceful degradation.** If chrome-devtools MCP or the dev server are
  unavailable, emit the skip note and proceed. Never block static passes on live
  inspection.
