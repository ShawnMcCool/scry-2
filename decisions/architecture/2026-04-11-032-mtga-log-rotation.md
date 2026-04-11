---
status: accepted
date: 2026-04-11
---
# 032. MTGA log rotation — detection, epoch tracking, and idempotency

## Status

Accepted

## Context and Problem Statement

MTGA writes all game session events to a single file: `Player.log`. When
MTGA restarts, it rotates this file by renaming `Player.log` →
`Player-prev.log` and creating a fresh `Player.log` that starts at byte
offset 0. This means two physically distinct files can share the same
filesystem path at different points in time.

Scry2's ingestion pipeline uniquely identifies raw log events by
`(source_file, file_offset)` — the absolute file path combined with the
byte offset of the event's start position inside that file. After a
rotation, this composite key is no longer globally unique: the new
`Player.log` will produce events at the same byte offsets (starting from
0) as events already stored in `mtga_logs_events` from the previous
`Player.log`.

`insert_event!/1` uses `on_conflict: :nothing` with
`conflict_target: [:source_file, :file_offset]`. When the new file's
events collide with old events at the same offset, they are **silently
dropped**. No warning is emitted. No error is raised. Events are
irrecoverably lost.

This failure was confirmed on 2026-04-11 when the dev server restarted
after a migration that had been pending while MTGA rotated its log:

- `Player-prev.log`: 39 MB (the previous session, already in the DB at
  offsets 0–40 MB under `source_file = ".../Player.log"`)
- `Player.log`: 2.6 MB (a new session, offsets 0–2.6 MB — overlapping
  entirely with offsets stored from the previous session)

Events in the new file whose byte offsets coincided with stored offsets
from the old file were dropped silently. The rest were inserted normally.

---

## MTGA Log Rotation — Technical Detail

### File lifecycle

| Phase | Player.log | Player-prev.log |
|-------|-----------|-----------------|
| During a session | Actively written by MTGA | Contains the previous session |
| At MTGA restart | Renamed to Player-prev.log | Deleted (previous Player-prev.log) |
| After restart | New empty file, written from byte 0 | Contains the session just ended |

MTGA keeps exactly two files on disk at any time. Older sessions are
discarded. If Scry2 fails to ingest events before the next rotation, those
events are permanently lost from the source — the only recovery path is
the `mtga_logs_events` table itself.

### Detection in Scry2

`ReadNewBytes.read_since/2` detects rotation by comparing the current file
size against the stored byte offset:

```elixir
# read_new_bytes.ex — rotation detection (lines 34-48)
cond do
  size < offset ->
    # File was truncated/rotated — re-read from byte 0
    case File.read(file_path) do
      {:ok, bytes} ->
        {:ok, %{bytes: bytes, new_offset: byte_size(bytes), rotated?: true, inode: inode}}
```

When `file_size < stored_offset`, the file has been replaced. The module
returns `rotated?: true` and reads the entire new file.

`Watcher.drain_file/1` responds by resetting `base_offset` to 0 so that
events parsed from the new file receive correct file_offsets starting at 0:

```elixir
# watcher.ex — base offset reset on rotation (line 185)
base_offset = if rotated, do: 0, else: offset
```

Detection is reliable: `Player.log` can only shrink if MTGA replaced it.
Truncation-in-place is not part of MTGA's behaviour.

### Why inode does not solve the uniqueness problem

The cursor schema already stores `inode`. However, inode alone cannot
fix the uniqueness problem:

1. **`mtga_logs_events` has no inode column.** Even if the watcher
   correctly identifies a rotation via inode change, the conflict target
   `(source_file, file_offset)` does not include inode — so insert
   conflicts still occur.

2. **Inode reuse.** The OS may reuse inodes across files, particularly on
   filesystems with many small files. An inode match does not guarantee
   file identity.

3. **Wine / Windows NTFS.** MTGA runs under Wine on Linux. The Proton
   Steam layer exposes NTFS via Wine; `File.stat/1` may return `inode: 0`
   or repeat the same inode for different files. Inode is unreliable as a
   cross-platform identity key.

---

## Decision Outcome

Chosen option: **log epoch counter**, because it is a monotonically
increasing integer that encodes "which physical file did this event come
from?" in a platform-independent, human-readable, and query-friendly way.

### What changes

A `log_epoch` integer column (default 0, not null) is added to both
`mtga_logs_cursor` and `mtga_logs_events`.

The unique constraint on `mtga_logs_events` changes from:

```
UNIQUE (source_file, file_offset)
```

to:

```
UNIQUE (source_file, log_epoch, file_offset)
```

The cursor row for a given `file_path` tracks the current epoch. When
`Watcher.drain_file/1` detects `rotated?: true`, it increments the epoch
before writing events and persists the new epoch to the cursor. All events
from the new file carry the incremented epoch. Events from different log
cycles can never collide, regardless of byte-offset overlap.

### Epoch semantics

- Epoch starts at 0 for the first observed log file (or for all existing
  rows via migration default).
- Epoch increments by 1 on each detected rotation. It never resets.
- Epoch is a property of the **file identity** — it is not tied to
  projection state. Calling `reset_all!()` or `replay_projections!()` does
  not alter the epoch; doing so would reintroduce the collision bug.
- A human reading the DB can immediately see how many log rotations have
  occurred and which events belong to which physical file.

### Epoch is not encoded in source_file

Encoding the epoch into the path string (e.g. `Player.log#1`) was
considered and rejected:

- `source_file` is a file path — querying by filename becomes awkward
- Encoding two concerns (path + identity) in a single column violates
  single responsibility
- ADR-016 reasons about `source_file` as a pure path for idempotency —
  this assumption would break

### Epoch is not a UUID or file hash

- UUIDs provide no human-readable ordering information
- Hashing the full log file on each rotation adds latency proportional to
  file size (potentially tens of megabytes)
- A counter is deterministic, debuggable, and zero-overhead

---

## Consequences

**Good:**
- Events from different rotation cycles are permanently distinguishable by
  epoch — no silent drops, no ambiguity.
- Existing data is unaffected: all rows receive `log_epoch = 0` via the
  migration default, which is semantically correct (they were all ingested
  from the first observed file at that path).
- The idempotency guarantee from ADR-016 is preserved and strengthened: the
  conflict target `(source_file, log_epoch, file_offset)` still correctly
  deduplicates events if the watcher re-reads overlapping bytes after a
  crash or restart within the same log cycle.
- `Player-prev.log` events that were stored before a rotation remain intact
  and can be replayed; new-file events occupy distinct epoch slots.

**Bad:**
- One new column in each of two tables (low cost).
- The watcher state and cursor struct gain a field (minor complexity).
- Any code that hard-codes `conflict_target: [:source_file, :file_offset]`
  must be updated (only `insert_event!/1` in `Scry2.MtgaLogIngestion`).

## Related Decisions

- ADR-012: Durable process design — cursor durability ensures epoch
  survives restarts correctly.
- ADR-015: Raw event replay — epoch makes the event log fully accurate as a
  replay source; without it, replaying from a post-rotation epoch would
  silently skip events.
- ADR-016: Idempotent log ingestion — this ADR extends the idempotency
  guarantee to cover log rotation in addition to crash-restart scenarios.
