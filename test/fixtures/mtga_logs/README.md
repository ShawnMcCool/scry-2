# MTGA log fixtures

Real `Player.log` samples captured from the wild. The parser test
suite is intentionally kept empty of synthetic fixtures so that every
regression test is backed by a real MTGA event block.

## How to capture

1. Enable **Options → View Account → Detailed Logs (Plugin Support)**
   inside MTGA.
2. Play a short session (one draft pick, one match, one deck submit is
   enough to seed several distinct event types).
3. Copy the relevant block(s) from `Player.log` into a file here, named
   after the event type, e.g. `event_match_created.log`. Keep only the
   `[UnityCrossThreadLogger]` header line and the JSON block that
   follows it.
4. Scrub any PII before committing (opponent usernames, Wizards account
   IDs — these are safe but replace your own screen name if you feel
   like it).

## Append-only

Per [ADR-010](../../../decisions/architecture/2026-04-05-010-regression-tests-append-only.md),
every test in `event_parser_test.exs` that references a fixture file is
permanent. If the parser breaks on a real fixture, fix the parser — not
the test.
