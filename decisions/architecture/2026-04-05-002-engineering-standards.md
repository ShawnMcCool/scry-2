# 002. Engineering standards: test-first and zero warnings

Date: 2026-04-05

## Status

Accepted

## Context

Scry2's ingestion pipeline runs silently in the background, tailing `Player.log` and persisting events into SQLite. Bugs are invisible — a misparsed event, a dropped match, a malformed upsert — and the first place the user notices is a broken dashboard or a missing draft. The system needs engineering standards that catch problems before they reach production, not after.

## Decision

Adopt test-first development and a zero-warnings policy as complementary disciplines.

**Test-first:**
- Write tests before implementation for all new features and bug fixes.
- Tests are the executable specification — if you can't write the test, the requirements aren't clear enough.
- Parser tests use real MTGA log fixtures observed in the wild — never synthetic event blocks.
- Parser and ingestion tests are mandatory and must never be deleted or weakened (see ADR-010).

**Zero warnings:**
- Application code and tests must compile and run with zero warnings.
- This includes unused variables, unused aliases, unused imports, and log output that indicates misconfiguration (e.g., HTTP requests hitting real endpoints instead of stubs).
- `mix precommit` enforces `--warnings-as-errors` before every change.

## Consequences

- Test-first catches ingestion bugs before they silently corrupt the SQLite store.
- Zero warnings eliminates dead code accumulation and catches misconfigured test stubs.
- Test-first requires discipline — writing tests for every change adds up-front time.
- Zero warnings can slow down exploratory work — every experiment must clean up after itself.
