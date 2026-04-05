# 010. Regression tests are append-only

Date: 2026-04-05

## Status

Accepted

## Context

Scry2's `EventParser` and downstream ingesters process `Player.log` events silently in the background. Bugs in either produce invisible data corruption — a misparsed match ID, a dropped draft pick, a malformed card reference. Both subsystems accumulate test suites where each test represents a specific real-world scenario that has caused or could cause silent failure. When code changes break these tests, there is a temptation to delete or weaken the failing test rather than fix the underlying code.

## Decision

Regression tests may only be added, never removed or weakened.

1. **Parser tests use real MTGA log fixtures observed in the wild** — never synthetic event blocks. Each distinct event type gets its own test case in `test/fixtures/mtga_logs/`. If a parser change causes an existing test to fail, fix the parser.
2. **Ingestion tests represent real processing scenarios.** Each test guards against a specific failure mode — silent data loss, duplicate matches, malformed upserts. If an ingestion change causes a test to fail, fix the ingester.
3. **Test assertions must not be weakened** (e.g., changing an exact match to a substring match, loosening numeric bounds) to accommodate a code change.

Complements [ADR-002](2026-04-05-002-engineering-standards.md), which establishes test-first discipline.

## Consequences

- The test suite is a monotonically growing record of real failure modes.
- Developers are forced to maintain backward compatibility or consciously handle migration.
- The test suite grows indefinitely and may slow down over time.
