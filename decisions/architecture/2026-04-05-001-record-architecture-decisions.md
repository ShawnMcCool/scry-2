# 001. Record architecture decisions

Date: 2026-04-05

## Status

Accepted

## Context

Architectural decisions for Scry2 span the top-level `CLAUDE.md` (principles), the schema modules, and git/jj history. There is no single place to find *why* a decision was made or what alternatives were rejected. New contributors — human or AI — would otherwise have to reverse-engineer rationale from code and comments.

## Decision

Record architecture decisions as [MADR 4.0 lean](https://adr.github.io/madr/) documents under `decisions/architecture/`. Each file is named `YYYY-MM-DD-NNN-kebab-title.md` with sequential numbering within the category. The lean format captures context, decision, and consequences without ceremony.

## Consequences

- Decision rationale is discoverable in one directory.
- The lean template keeps each ADR short — easy to write and review.
- Existing decisions can be retroactively documented.
- Retroactive ADRs approximate the original decision date rather than recording it exactly.
