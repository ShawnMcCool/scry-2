# 003. Coding standards: human-readable names, domain-driven structure

Date: 2026-04-05

## Status

Accepted

## Context

As Scry2's codebase grows, inconsistent naming and ad-hoc module organization make it harder for contributors to navigate and understand the code. Abbreviated variable names (`ev`, `m`, `res`) save keystrokes but force readers to mentally decode every binding. Modules organized by technical role rather than domain concept scatter related logic across the project.

## Decision

Adopt human-readable naming and domain-driven module structure. Code is read far more often than it is written, and the project's primary maintenance cost is comprehension, not typing.

**Naming:**
- Never abbreviate variables to save keystrokes. `event` not `ev`, `match` not `m`, `card` not `c`, `result` not `res`.
- Name the variable what the value *is*, not what type it came from. A parsed log event representing a draft pick should be called `pick` or `draft_pick`, not `event` or `ev`.
- This applies everywhere: tests, GenServers, LiveViews, Ecto changesets.

**Module structure:**
- Organize by domain context (`Scry2.MtgaLogs`, `Scry2.Matches`, `Scry2.Drafts`, `Scry2.Cards`, `Scry2.Settings`), not by technical role.
- Each domain context has a clear public API surface. Internal modules are implementation details.
- Cross-context interaction uses PubSub events, not direct function calls into another context's internals.

**Readability:**
- Write code for humans to read first, compilers second.
- Prefer explicit, boring code over clever abstractions. Three similar lines are better than a premature abstraction.
- Functions and modules should be understandable from their names alone.

## Consequences

- New contributors can read the code without a glossary of abbreviations.
- Domain-driven structure makes it obvious where new code belongs.
- Explicit naming catches incorrect assumptions early — a misnamed variable reveals a misunderstood data flow.
- Longer names require more horizontal space — an acceptable trade-off for clarity.
