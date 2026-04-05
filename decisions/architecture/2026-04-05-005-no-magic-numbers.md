# 005. No magic numbers

Date: 2026-04-05

## Status

Accepted

## Context

Numeric and string literals scattered through implementation code are hard to find, hard to change, and give no indication of *why* that value was chosen. When the same value appears in multiple places, they drift apart silently. Worse, some values are policy decisions that users should be able to override — but burying them in code makes that impossible without a code change.

## Decision

Extract literals to the appropriate level of configuration.

1. **Name every significant literal.** Extract numbers, durations, thresholds, sizes, and path fragments into module attributes (`@poll_interval_ms`, `@max_retries`, `@detailed_logs_check_count`). The name documents intent; the value is easy to find and change.
2. **Promote to app config when the value is environment-sensitive.** If a value should differ between dev, test, and prod, it belongs in `config/*.exs` and is accessed via `Scry2.Config.get/1`. Examples: timeouts, batch sizes, rate limits.
3. **Promote to user config when the value is a policy decision.** If the user should reasonably want to tune it, add it to `Scry2.Config.get/1` with a default in `defaults/scry_2.toml` and a comment explaining what it controls. Examples: `player_log_path`, `lands17_refresh_days`.
4. **Don't over-extract.** Some literals are inherently fixed and well-understood in context: `0`, `1`, `""`, list indices, HTTP status codes (`200`, `404`), and mathematical constants. Use judgment — if the meaning is immediately obvious and the value will never change, leave it inline.
5. **Keep `defaults/scry_2.toml` complete.** Every key recognized by `Scry2.Config` must appear in the defaults file with a sensible value and a comment.

## Consequences

- Intent is documented — `@max_retries` explains what `3` means in context.
- Changing a value requires editing one place, not grepping the codebase.
- User-tunable policy decisions are discoverable in `defaults/scry_2.toml`.
- Requires judgment calls on which tier a value belongs to — not every case is obvious.
