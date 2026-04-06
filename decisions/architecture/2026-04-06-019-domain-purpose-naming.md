# 019. Name modules by domain purpose, not design pattern

Date: 2026-04-06

## Status

Accepted

## Context

As Scry2's module tree grew, many modules were named after the design pattern they implement — Translator, Projector, Importer, Worker, Buffer, Handler — rather than what they do in the domain. A reader scanning the module tree needs to already understand event sourcing, anti-corruption layers, and projection patterns before the names communicate anything. The codebase should be self-narrating: a new reader should understand the business process from module names alone, without architecture knowledge.

This extends ADR-003 (human-readable names, domain-driven structure). ADR-003 established that variables should be named for what the value *is* and modules should be organized by domain context. This decision takes the next step: within each context, individual modules should be named for what they *do*, not what pattern they *are*.

## Decision

Name every module for what it does in the domain, not what design pattern it implements.

**Context names** describe the domain purpose of the bounded context:
- `MtgaLogIngestion` (not `MtgaLogs`) — the context ingests MTGA logs
- `Matches` — the context owns match projection data
- `Drafts` — same pattern

**Internal module names** read as actions or domain descriptions:
- `IdentifyDomainEvents` (not `Translator`) — identifies which domain events occurred in raw data
- `ExtractEventsFromLog` (not `EventParser`) — extracts structured events from raw log text
- `UpdateFromEvent` (not `Projector`) — updates the read model from a domain event
- `SeventeenLands` (not `Lands17Importer`) — the 17lands integration
- `PeriodicallyUpdateCards` (not `CardsRefreshWorker`) — periodically updates card data
- `IngestRawEvents` (not `IngestionWorker`) — ingests raw events into the domain event log
- `RecentEntries` (not `Buffer`) — manages recent log entries
- `CaptureLogOutput` (not `Handler`) — captures Erlang logger output

**What stays unchanged:**
- Table names are stable database identifiers — they don't change
- PubSub topic strings are stable wire identifiers — they don't change
- Domain event structs are already domain-named (MatchCreated, DraftPickMade)
- Data structs that describe what they *are* rather than a pattern (Filter, Entry, Cursor, Event)

**The test:** when naming a module, ask "what does this do?" not "what pattern is this?" If the name only makes sense to someone who knows the pattern, rename it.

## Consequences

- New contributors can read the module tree and understand the business process without architecture knowledge.
- Module names become greppable by domain concept — searching for "domain events" finds `IdentifyDomainEvents` and `IngestRawEvents`.
- Some names are longer than their pattern equivalents — an acceptable trade-off for clarity.
- Pattern knowledge is still useful for understanding *how* a module works, but is no longer required to understand *what* it does.
- Existing ADRs and documentation must be updated to reference new names.
