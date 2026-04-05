# 004. Test through the public interface

Date: 2026-04-05

## Status

Accepted

## Context

When a private function contains complex logic, there is a temptation to promote it to `def` (or tag it `@doc false`) just so tests can call it directly. This couples tests to implementation details, making refactoring painful — every internal restructure breaks tests even when external behavior has not changed.

Elixir's module system makes this especially important: a `defp` that is hard to test usually means the module is doing too much or the logic should live in its own module with a clear public API.

## Decision

Test behavior through the public API. Extract when needed.

1. **Never promote `defp` to `def` for testability.** If a private function needs direct testing, extract it into its own module with a proper public API.
2. **Test observable behavior.** Call the public function with inputs that exercise the private path you care about. If you can't reach a code path through the public API, question whether that path should exist.
3. **Extract pure logic into dedicated modules.** Complex computation hiding inside a GenServer callback or LiveView handler belongs in a pure-function module (e.g., `EventParser`, `Mapper`) that is trivially testable.
4. **Keep tests simple.** Modular code means each test targets a small public surface. If a test requires elaborate setup to reach a private code path, that is the design signal — extract, don't expose.

## Consequences

- Tests survive internal refactoring — only public contract changes require test updates.
- Drives modular design: complex private logic naturally migrates into focused, reusable modules.
- Aligns with existing patterns (`Scry2.MtgaLogs.EventParser` is a pure module extracted for this reason).
- Testing a specific edge case may require more thoughtful input construction to exercise it through the public API.
