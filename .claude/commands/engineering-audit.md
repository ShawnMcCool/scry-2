---
description: Thorough code quality analysis — inconsistencies, missing abstractions, readability, structure, and test policy compliance.
argument-hint: "[path-or-module (optional)]"
---

# Engineering Audit

You are performing a meticulous code review and quality analysis of an Elixir/Phoenix/Ecto
codebase. Your goal is to find real, actionable issues — not to generate noise. Every
finding must be specific, cite the exact file and line, and explain *why* it matters.

**Scope:** If `$ARGUMENTS` is provided, focus the analysis on that path or module.
Otherwise, analyze the full `lib/` tree.

Read the project's `CLAUDE.md` before beginning — it defines the architecture principles,
testing strategy, and coding conventions you are auditing against.

---

## Analysis Passes

Work through each pass sequentially. For each pass, explore the relevant code thoroughly
using file reads and searches. Do not guess — read the actual source.

### Pass 1 — Inconsistencies

Look for inconsistencies across the codebase:

- **Naming inconsistencies:** Are similar concepts named differently in different modules?
  Are there synonyms where a single term should be used? (e.g., `event` vs `record` vs
  `entry` for the same concept, `parse` vs `decode` for the same operation)
- **Pattern inconsistencies:** Are similar operations handled differently in different
  places? (e.g., one module uses `case` for dispatch while an analogous module uses `cond`;
  one context wraps calls in public functions while another exposes Repo directly;
  one pipeline stage handles errors one way while a sibling does it differently)
- **Style inconsistencies:** Module structure, alias ordering, function grouping, or
  structural conventions that vary without reason between peer modules.
- **API shape inconsistencies:** Do peer modules expose inconsistent function signatures
  for equivalent operations?
- **Context function inconsistencies:** Do peer contexts expose similar CRUD operations
  with different function naming conventions (`create_*` vs `insert_*`, `get_*` vs `fetch_*`)?
  Are changeset builders named consistently across schemas?

### Pass 2 — Duplication & Missing Abstractions

Look for code that is duplicated or nearly duplicated, which may signal a missing
abstraction:

- **Literal duplication:** Identical or near-identical blocks of code appearing in multiple
  locations.
- **Structural duplication:** Different modules that follow the same multi-step pattern but
  implement it independently — a sign that a shared module, behaviour, or macro could unify
  them.
- **Data duplication:** The same concept represented in multiple structs or computed in
  multiple places.
- **Missed behaviour opportunities:** Multiple modules that implement the same informal
  contract (same function names, same arities) but don't share a behaviour.

For each finding, suggest the abstraction that would eliminate the duplication — but only
if the abstraction would genuinely simplify the code. Three similar lines are better than
a premature abstraction.

### Pass 3 — Readability & Expressiveness

Code should read like prose. A domain-driven design practitioner should understand the
intent without deciphering implementation tricks.

- **Function names:** Do they describe *what* they do in domain terms, not *how* they do
  it? Are they specific enough to distinguish from peers?
- **Variable names:** Do local bindings tell you what they hold? Are there single-letter
  variables outside of trivial closures or comprehensions? Does the code follow the project's
  variable naming rules (no abbreviations, name the value not the type)?
- **Module names and file organization:** Does the directory structure reflect the domain?
  Can you understand what a module does from its path alone?
- **Control flow clarity:** Are there deeply nested `case`/`cond`/`with` blocks that could
  be flattened? Are there long functions that do multiple unrelated things?
- **Pattern match expressiveness:** Are pattern matches used effectively to make impossible
  states unrepresentable? Are there raw primitives where a struct or tagged tuple would add
  clarity?
- **Comment quality:** Are comments explaining *why*, not *what*? Are there stale comments
  that no longer match the code?

### Pass 4 — Project Structure

Evaluate the module hierarchy:

- **Bounded contexts:** Does each top-level module under `lib/scry_2/` represent a clear
  domain boundary? Are there modules that mix concerns?
- **Dependency direction:** Do modules depend in the right direction? (Domain logic should
  not depend on LiveView; Ecto schemas and context modules should not depend on pipeline
  logic; projectors should not depend on each other.)
- **Cohesion:** Are related functions and modules co-located? Are there functions that would
  be more discoverable in a different module?
- **Public API surface:** Are modules exposing more than they need to? Are there public
  functions that are only used internally?
- **Context API organization:** Do the public functions exposed by each top-level context
  module (`MtgaLogIngestion`, `Events`, `Matches`, `Drafts`, `Cards`, `Settings`, `Console`)
  match the underlying schemas they wrap? Are there dead wrapper functions, or schemas
  without a public context API?
- **PubSub discipline:** Cross-context communication must go through `Scry2.Topics` PubSub
  helpers only. Flag any direct alias or call from one context module to another context's
  internal modules.

### Pass 5 — Test Policy Compliance

Audit tests against the project's testing strategy (defined in CLAUDE.md):

- **Coverage of testable code:** For every pure function module (`ExtractEventsFromLog`,
  `IdentifyDomainEvents`, `EnrichEvents`, `IngestionState`, `LocateLogFile`, `ReadNewBytes`,
  `ParseWarning`, `TranslationWarning`) and every `*_helpers.ex` module — is there a
  corresponding test? List any gaps.
- **Factory usage:** Are tests using the shared `TestFactory` (`build_*` for pure tests,
  `create_*` for DB tests)? Flag any inline `Ecto.Changeset.cast`/`Repo.insert!` boilerplate
  that duplicates the factory.
- **No tests for untestable code:** Are there tests that assert on rendered HTML, test
  GenServer internals via `:sys.get_state`, or use direct `GenServer.call/cast` instead of
  the module's public API? These violate the testing policy.
- **Test quality:** Are there brittle tests that depend on implementation details rather
  than behavior? Are there tests with no meaningful assertion?
- **Parser test-first mandate:** Do parser tests cover real scenarios with real log
  fixtures? Flag any that appear to test trivial or synthetic cases.
- **Zero warnings:** Are there test files that would produce warnings (unused variables,
  unused aliases)?

### Pass 6 — Compiler & Lint Health

- Flag any code that `mix compile --warnings-as-errors` would catch: unused imports, unused
  variables, unused aliases, unreachable clauses.
- Flag any `String.to_atom` or `String.to_existing_atom` calls with untrusted input.
- Flag any `Repo.*` calls from outside a top-level context module (contexts should own
  their Repo access; LiveViews and other consumers go through context public APIs).
- Flag any `Repo.all`, `Repo.delete_all`, or `Repo.update_all` in loops where a single
  batched query would work — N+1 patterns in disguise.
- Flag any dead code: functions defined but never called, modules defined but never aliased.

---

## Output Format

Present findings grouped by pass. For each finding:

1. **Location** — exact file path and line number(s)
2. **Issue** — one-sentence description
3. **Why it matters** — brief explanation grounded in project principles
4. **Suggested fix** — concrete, minimal change (or "no change needed, noting for
   awareness" if it's a judgment call)

At the end, provide a **summary** with:
- Total findings per pass
- Top 3 highest-impact improvements
- An overall health assessment (one paragraph)

Do not manufacture findings — but do not manufacture praise either. If an area is clean, a
single sentence suffices. Spend your words on problems, not compliments.
