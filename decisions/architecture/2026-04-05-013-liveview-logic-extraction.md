# 013. Extract LiveView behavior into tested pure functions

Date: 2026-04-05

## Status

Accepted

## Context

LiveView components accumulate conditional logic — state classification, label computation, variant selection, absence detection, data transformation — inlined in templates and private component functions. This logic is untestable without rendering HTML, which is fragile and couples tests to DOM structure rather than behavior.

For Scry2's admin UI, examples of logic prone to inlining include: "is this match incomplete?", "what label do we show for a draft in progress?", "which icon represents a card with no `arena_id`?". If these live only inside templates, they cannot be unit tested, and regressions slip through silently.

## Decision

All non-trivial logic in LiveViews and function components must be extracted into public pure functions with unit tests.

1. **LiveViews are thin wiring.** A LiveView module handles mount, event dispatch, and template rendering. Any logic beyond trivial assignment (an `if`, `case`, `cond`, or `Enum` pipeline on domain data) must be extracted into a public function.
2. **Extract into the same module or a dedicated helper.** Small helpers (1–3 functions) can live as public functions in the LiveView or component module. Larger clusters belong in a dedicated module (e.g., `MatchListHelpers`).
3. **Extracted functions must have unit tests.** Use `async: true` with `build_*` factory helpers — no database, no rendering. Test inputs and outputs directly.
4. **Never assert on rendered HTML.** No `render_component`, no `=~` on markup, no CSS selector assertions on rendered output. LiveView integration tests (mount, patch, event handling via `Phoenix.LiveViewTest`) are acceptable — they test navigation and data flow, not DOM structure.

**Examples of logic that must be extracted:**
- State classification: `match_complete?(match)`, `draft_status(draft)`
- Label computation: `match_result_label(match)`, `card_display_name(card)`
- Variant selection: `icon_for_event_type(type)`, `badge_class(status)`
- Data transformation: `group_picks_by_pack(picks)`, `sort_matches(matches)`

## Consequences

- Logic bugs are caught by fast async unit tests that run in milliseconds.
- Forces clear API boundaries between data logic and presentation.
- Extracted functions are reusable across LiveViews and components.
- Refactors that change schemas break tests at the function level, not at the HTML rendering level.
- Introduces more public functions and potentially more modules — but each is small, focused, and independently testable.
