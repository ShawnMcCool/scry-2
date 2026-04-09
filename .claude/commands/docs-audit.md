---
description: Systematic documentation audit — structural accuracy, staleness, clarity, and cross-reference integrity verified against actual source code.
argument-hint: "[file-or-path (optional)]"
---

# Documentation Audit — Systematic Validation

You are performing a meticulous documentation audit of Scry 2.
Your goal is to find real, actionable issues — not to generate noise. Every finding
must cite the exact documentation file, the source file(s) that contradict it, and
explain the discrepancy with evidence.

**Brutal honesty is mandatory.** Do not soften findings, hedge with qualifiers, or
balance criticism with unearned praise. If the documentation is stale, misleading, or
incomplete, say so directly. The user wants to know what's wrong — they already know
what's right. A sycophantic audit is worse than no audit at all.

**Scope:** If `$ARGUMENTS` is provided, focus on that file or path. Otherwise, audit
all documentation in the current project.

**The cardinal rule: read the code.** Every accuracy claim you verify must be checked
against actual source files, not against other documentation. Documents can be wrong
about each other — only the source code and the filesystem are ground truth.

Before beginning, identify the project's documentation files by globbing for `*.md`
files in the project root, `decisions/`, and any spec files. Read `CLAUDE.md` to
understand the project's stated architecture and conventions.

---

## Analysis Passes

Work through each pass sequentially. For each pass, explore the relevant documentation
and source code thoroughly. Do not guess — read the actual files.

### Pass 1 — Structural Accuracy

Verify that documentation claims match the actual codebase. Check each of these
categories:

- **File paths and module references:** Every path mentioned in docs (e.g.
  `lib/scry_2/`, `lib/scry_2_web/live/`, `defaults/scry_2.toml`) must
  exist on disk. Glob to verify.
- **Config fields:** Every field documented in CLAUDE.md or referenced in docs must
  exist in `Scry2.Config`. Every config field in the source should be documented.
  Check that defaults match `defaults/scry_2.toml`.
- **Bounded context tables:** The context/table map in CLAUDE.md claims each context
  owns specific tables (e.g. `mtga_logs_events`, `matches_*`, `drafts_*`, `cards_*`,
  `settings_entries`). Verify against actual Ecto schemas under `lib/scry_2/`.
- **Architecture claims:** Statements about how components interact (e.g. "only
  `IngestRawEvents` subscribes to `mtga_logs:events`", "the watcher is read-only",
  "all cross-context communication goes through PubSub") should be spot-checked
  against actual code. Are the stated principles being followed?
- **Build commands:** Verify that documented build/run/test commands (`mix setup`,
  `mix phx.server`, `mix test`, `mix precommit`) work as described.
- **Decision records:** Check that ADR references in CLAUDE.md point to files that
  exist in `decisions/architecture/` or `decisions/user-interface/`.
- **Bounded context descriptions:** The context table in CLAUDE.md lists each
  context's prefix, ownership, and PubSub role. Verify each entry against actual
  modules and schemas.

### Pass 2 — Freshness

Find documentation that has gone stale:

- **Removed files still referenced:** Are there references to files, modules, or
  dependencies that no longer exist?
- **Dead TODOs:** Are there TODO comments in documentation that reference completed
  work or obsolete plans?
- **Outdated dependency references:** Are there references to dependencies or libraries
  that have been replaced or removed? Check `mix.exs` against doc claims.
- **Stale testing instructions:** Do documented test commands and patterns match what
  `test/` actually contains?
- **Stale ADR references:** Do ADR numbers and filenames referenced in CLAUDE.md or
  code `@moduledoc` strings match actual files in `decisions/`?

### Pass 3 — Clarity & Conciseness

Evaluate documentation quality and organization:

- **Cross-document duplication:** Are the same concepts duplicated across CLAUDE.md,
  AGENTS.md, and decision records? Flag cases that create sync burden and drift risk.
- **Audience confusion:** CLAUDE.md is AI agent instructions; AGENTS.md is coding
  guidelines; decision records are architectural rationale. Flag content in the wrong
  file for its audience.
- **Verbose sections:** Flag sections that could be significantly shorter without losing
  information.
- **Unclear jargon:** Flag domain terms used without definition.
- **Missing context:** Flag sections that assume knowledge not provided elsewhere.

### Pass 4 — Cross-Reference Integrity

Verify that documents reference each other correctly:

- **Broken markdown links:** Check every `[text](url)` link in all docs. For relative
  links, verify the target file exists.
- **Decision record references:** Check that ADR numbers and filenames referenced in
  CLAUDE.md and other docs match actual files in `decisions/architecture/` and
  `decisions/user-interface/`.
- **UIDR compliance claims:** Any claim in CLAUDE.md or AGENTS.md about UI conventions
  (badge styles, button conventions, stat card component, show-don't-hide) should
  cross-reference the appropriate file in `decisions/user-interface/`.
- **@moduledoc ADR references:** Modules that reference ADRs in their `@moduledoc`
  should point to ADR files that exist and whose content matches the claim.

---

## Output Format

Present findings grouped by pass. For each finding:

1. **Document** — the documentation file containing the issue
2. **Source** — the source file(s) or filesystem evidence that reveals the issue
3. **Issue** — one-sentence description of the discrepancy
4. **Evidence** — the specific text in the doc and what the source actually shows
5. **Suggested fix** — concrete, minimal change to resolve the issue

At the end, provide a **summary** with:

- Total findings per pass
- Top 5 highest-impact improvements
- An overall documentation health assessment (one paragraph)

---

## Rules

- **Do not modify any files.** This is an analysis-only audit.
- **Evidence, not speculation.** Only flag discrepancies you can prove by reading the
  source.
- **Cite every finding.** Every issue must include the exact doc file and the source
  file(s) that contradict it.
- **No unearned praise.** If documentation is genuinely accurate in some area, one
  sentence suffices. Spend your words on problems.
- **Scope to arguments.** If `$ARGUMENTS` names a specific file or path, analyze only
  that area.
