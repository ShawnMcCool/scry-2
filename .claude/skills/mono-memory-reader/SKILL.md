---
name: mono-memory-reader
description: Use when working on Scry2.Collection's walker path — the Rust NIF crate under native/scry2_collection_reader that navigates MTGA's in-process Mono runtime. Covers the pointer chain, Mono struct offsets, PE/prologue decoding, and the canonical sources for cross-verification.
---

# MTGA Mono Memory Reader

Technical reference for the **walker path** of `Scry2.Collection`'s reader
(the Rust NIF crate at `native/scry2_collection_reader/`). The walker
resolves MTGA's live collection, wildcards, gold, gems, and vault progress
by walking named pointers through the process's Mono runtime.

For the fallback **structural-scan path**, see the POC at
`mtga-duress/experiments/mtga-reader-poc/`.

## MTGA runtime identity

| Property | Value |
|---|---|
| Engine | Unity 2022.3.62f2 (Proton/Wine on Linux) |
| Scripting backend | Mono (not IL2CPP) |
| Mono runtime DLL | `mono-2.0-bdwgc.dll` (MonoBleedingEdge) |
| Mono DLL on-disk | `$STEAM/common/MTGA/MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll` |
| Managed assemblies | `Core.dll`, `Assembly-CSharp.dll`, `SharedClientCore.dll` |
| PE layout | PE32+, `ImageBase = 0x180000000` |

MTGA's `mono-2.0-bdwgc.dll` on-disk and mapped bytes are byte-identical
across its read-only code sections. The disassembly below is derived from
the on-disk file; verification against live memory is a straight
`read_bytes` at the RVA.

## The pointer chain

From the Unity 2022.3.62f2 build, the walker navigates:

```
mono_get_root_domain()                  -> MonoDomain *
  (walk assemblies to Core.dll or Assembly-CSharp.dll)
  class PAPA
    <Instance>k__BackingField           (STATIC field — read via VTable)
      <InventoryManager>k__BackingField (instance)
        _inventoryServiceWrapper        (instance)
          <Cards>k__BackingField        -> Dictionary<int,int>   (collection)
          m_inventory                   -> ClientPlayerInventory
                                            { wcCommon, wcUncommon,
                                              wcRare,  wcMythic,
                                              gold, gems, vaultProgress,
                                              boosters: List<ClientBoosterInfo> }
```

**`ClientPlayerInventory` instance fields** (16 total; verified
2026-05-02 via `inventory-field-spike` —
`mtga-duress/experiments/spikes/spike18_booster_inventory/FINDING.md`):

| Offset | Field | Type | Notes |
|---:|---|---|---|
| `0x0010` | `boosters` | `List<ClientBoosterInfo>` | booster inventory; element layout below |
| `0x0018` | `vouchers` | reference | (shape unverified — likely a list/dict) |
| `0x0020` | `prizeWallsUnlocked` | reference | (cosmetic) |
| `0x0028` | `basicLandSet` | reference | (cosmetic) |
| `0x0030` | `latestBasicLandSet` | reference | (cosmetic) |
| `0x0038` | `starterDecks` | reference | |
| `0x0040` | `tickets` | reference | (event entry tokens) |
| `0x0048` | `CustomTokens` | reference | |
| `0x0050` | `wcCommon` | i32 | walker phase 6 |
| `0x0054` | `wcUncommon` | i32 | walker phase 6 |
| `0x0058` | `wcRare` | i32 | walker phase 6 |
| `0x005c` | `wcMythic` | i32 | walker phase 6 |
| `0x0060` | `gold` | i32 | walker phase 6 |
| `0x0064` | `gems` | i32 | walker phase 6 |
| `0x0068` | `wcTrackPosition` | i32 | wildcard track progress |
| `0x0070` | `vaultProgress` | f64 | walker phase 6 (System.Double) |

**`ClientBoosterInfo` element fields** (verified 2026-05-02; same
spike):

| Offset | Field | Type |
|---:|---|---|
| `0x0010` | `collationId` | i32 (matches MTGA's log `Changes[*].Boosters[].collationId`) |
| `0x0014` | `count` | i32 |

**Field resolution rule** (from spike 5):
1. Exact name match first.
2. Fall back to `<UpperCamel>k__BackingField` (C# auto-property backing
   field) — with a single leading underscore stripped and first letter
   uppercased on the requested name.
3. Static vs instance: dispatch on `MONO_FIELD_ATTR_STATIC = 0x10` in
   `MonoClassField.type->attrs`. Static reads from
   `vtable->data[field->offset]`; instance reads from
   `obj_ptr + field->offset`.

## Match-state pointer chains (verified 2026-04-30)

Beyond the inventory chain, the walker has two more chains for
in-match data. Both were validated end-to-end against MTGA build
timestamp `Fri Apr 11 17:22:20 2025` on 2026-04-30 — see
`mtga-duress/experiments/spikes/spike16_match_manager/FINDING.md`
for the full evidence.

**Two-source coverage** for these chains:
1. Untapped's decompiled TypeScript sources in
   `mtga-duress/experiments/untapped-analysis/source-maps/` (clean-room
   rule per DOSSIER.md — idea, not code).
2. Live disassembly + offset dump via `match-manager-spike` (sibling
   binary in the production crate, `src/bin/match_manager_spike.rs`).

### Chain 1 — match info (rank, commander) — VERIFIED

Anchored at the same `PAPA._instance` static the inventory walker
uses. Provides what the log can never deliver — opponent rank and
real screen name.

**PAPA instance fields** (47 total; only the relevant ones listed):

| Offset | Field | Notes |
|---:|---|---|
| `0x0000` | `_instance` | STATIC, attrs `0x0011` — singleton anchor |
| **`0x0138`** | **`<MatchManager>k__BackingField`** | instance, attrs `0x0001` |
| `0x00e8` | `<InventoryManager>k__BackingField` | (existing inventory walker uses this) |

**MatchManager instance fields** (43 total; relevant to rank/commander
extraction):

| Offset | Field | Type |
|---:|---|---|
| `0x0048` | `<MatchID>k__BackingField` | string ref |
| `0x0058` | `<LocalPlayerInfo>k__BackingField` | `PlayerInfo *` |
| `0x0060` | `<OpponentInfo>k__BackingField` | `PlayerInfo *` |
| `0x0068` | `Players` | collection (List/Dict) of all PlayerInfo |
| `0x0098` | `<Event>k__BackingField` | `EventContext *`, null when not in event |
| `0x0108` | `<LocalPlayerSeatId>k__BackingField` | i32 |
| `0x010c` | `<WinCondition>k__BackingField` | i32 enum |
| `0x0110` | `<CurrentGameNumber>k__BackingField` | i32 |
| `0x0114` | `<MatchState>k__BackingField` | i32 enum |
| `0x0118` | `<Format>k__BackingField` | i32 enum |
| `0x011c` | `<Variant>k__BackingField` | i32 enum |
| `0x0120` | `<SessionType>k__BackingField` | i32 enum |
| `0x0125` | `<IsPracticeGame>k__BackingField` | bool (1 byte) |
| `0x0126` | `<IsPrivateGame>k__BackingField` | bool |

**PlayerInfo class** (used for both `LocalPlayerInfo` and
`OpponentInfo` — same class, 19 fields):

| Offset | Field | Type | Notes |
|---:|---|---|---|
| `0x0000` | `PrivateMatchOpponentNotJoinedYet` | STATIC | skip in instance reads |
| `0x0010` | `_screenName` | `MonoString *` | real opponent username (closes log gap) |
| `0x0018` | `WizardsAccountIdForPrivateGaming` | string ref | |
| `0x0040` | `_deckCards` | `List<???>*` | private readonly. **Empty for OpponentInfo** — client never has opponent's submitted deck |
| `0x0048` | `_sideboardCards` | `List<???>*` | same as above |
| `0x0050` | `_cardStyles` | `List<???>*` | |
| `0x0058` | `<CommanderGrpIds>k__BackingField` | `List<i32>*` | populated for Brawl/Commander |
| `0x0060` | `<EmoteSelection>k__BackingField` | ref | |
| `0x0068` | `SeatId` | i32 | |
| `0x006c` | `TeamId` | i32 | |
| `0x0070` | `IsWotc` | bool | |
| **`0x0074`** | **`RankingClass`** | **i32 enum** | `[None, Bronze, Silver, Gold, Platinum, Diamond, Mythic]` (index 0..6) |
| **`0x0078`** | **`RankingTier`** | **i32** | 1..4 within each class |
| **`0x007c`** | **`MythicPercentile`** | **i32 (probable)** | 0 for sub-Mythic; live verification with a Mythic player needed to disambiguate i32 vs f32 |
| **`0x0080`** | **`MythicPlacement`** | **i32** | leaderboard placement for top players |

**Tear-down behaviour (critical):** after a match completes, MTGA
**resets both `LocalPlayerInfo` and `OpponentInfo` to placeholder
defaults** — `_screenName` reverts to `"Local Player"` / `"Opponent"`,
all rank ints zero, `_deckCards._size = 0`, `Event` becomes null. The
underlying objects persist; only the values are wiped. **A one-shot
read at `MatchCompleted` log-event time is too late.** Read at
`MatchCreated` instead — the opponent's PlayerInfo is populated from
the moment ConnectResp arrives.

```
PAPA._instance                                       (existing anchor)
  .MatchManager                                      (instance)
    .Event.PlayerEvent.Format.UseRebalancedCards   : bool  (nullable chain)
    .LocalPlayerInfo
      .RankingClass                                : enum [None, Bronze,
                                                          Silver, Gold,
                                                          Platinum,
                                                          Diamond, Mythic]
      .RankingTier                                 : i32
      .MythicPercentile                            : f32 / f64 (TBD)
      .MythicPlacement                             : i32
      .CommanderGrpIds                             : List<i32>
    .OpponentInfo
      .RankingClass, .RankingTier,
      .MythicPercentile, .MythicPlacement,
      .CommanderGrpIds                             : (same shape as above)
```

`OpponentInfo` is the gap-filler — MTGA does not include opponent
rank in match-room log events. `CommanderGrpIds` is the Brawl/
Commander commander identity.

Source: `ScryIpcHandler-x0rjOwCx/src/scry/readers/mtga/ScryMtgaMatchInfo.ts`.

### Chain 2 — board state (every card, every zone, both players) — VERIFIED

Anchored at the `MatchSceneManager` class's static `Instance` field —
distinct from the PAPA anchor used by Chain 1.

**MatchSceneManager class** (looked up by name in the loaded images;
addr varies per build):

| Offset | Field | Notes |
|---:|---|---|
| `0x0000` | `Instance` | STATIC, attrs `0x0016` — **becomes NULL after match scene tears down** |
| `0x0078` | `_gameManager` | instance, attrs `0x0001` — `GameManager *` |

**GameManager instance fields** (50 total; relevant fields):

| Offset | Field | Notes |
|---:|---|---|
| `0x0050` | `<CardHolderManager>k__BackingField` | instance |
| `0x00c0` | `<MatchManager>k__BackingField` | instance — alternative path to MatchManager (PAPA path is simpler) |
| `0x0118` | `_gameStateManager` | instance, attrs `0x0021` — additional state worth probing |

**CardHolderManager class** (5 fields):

| Offset | Field |
|---:|---|
| `0x0010` | `<DefaultBrowser>k__BackingField` |
| `0x0018` | `<Examine>k__BackingField` |
| `0x0020` | `_provider` (private, attrs `0x0021`) — `MutableCardHolderProvider *` |
| `0x0028` | `_builder` |
| `0x0030` | `_zoneCardHolderCreated` |

**MutableCardHolderProvider class** (4 fields, all `Dictionary\`2`):

| Offset | Field |
|---:|---|
| `0x0010` | `ZoneIdToCardHolder` |
| `0x0018` | `SubCardHolderMap` |
| **`0x0020`** | **`PlayerTypeMap`** ← `Dict<GREPlayerNum, Dict<CardHolderType, ICardHolder>>` |
| `0x0028` | `AllCardHolders` |

```
GREPlayerNum   = { Invalid=0, LocalPlayer=1, Opponent=2, Teammate=3 }
CardHolderType = { Invalid=0, Library=1, OffCameraLibrary=2, Hand=3,
                   Battlefield=4, Graveyard=5, Exile=6, Stack=9,
                   Command=10, CardBrowserDefault=12,
                   CardBrowserViewDismiss=13, Examine=16,
                   Deckbuilder=17, CardViewer=18, Store=19,
                   RolloverZoom=20, Reveal=21, None=-1 }
```

**Tear-down behaviour:** the `MatchSceneManager.Instance` static is
nulled out as soon as MTGA exits the match scene — verified post-
match via `match-manager-spike`. The class definition stays loaded;
only the singleton pointer goes to zero. Reads must complete during
the match.

For non-battlefield zones, each holder is a `BaseCardHolder`:

```
BaseCardHolder._previousLayoutData : List<CardLayoutData>

CardLayoutData
  .IsVisibleInLayout : bool
  .Card : BaseCDC
    ._model : CardDataAdapter
      ._printing : CardPrintingData       (Scryfall-shape — large)
      ._instance
        .BaseGrpId             : i32      ← arena_id
        .OverlayGrpId.value    : i32      (alt-art arena_id; nullable)
        .IsTapped              : bool
        .FaceDownState._reasonFaceDown : enum
```

Battlefield is the special case — it's split into regions instead of
a flat list:

```
BattlefieldCardHolder.Layout
  ._localCreatureRegion       : BattlefieldRegion
  ._localLandRegion           : BattlefieldRegion
  ._localArtifactRegion       : BattlefieldRegion
  ._localPlaneswalkerRegion   : BattlefieldRegion
  ._opponentCreatureRegion    : BattlefieldRegion
  ._opponentLandRegion        : BattlefieldRegion
  ._opponentArtifactRegion    : BattlefieldRegion
  ._opponentPlaneswalkerRegion: BattlefieldRegion

BattlefieldRegion
  ._stacksByShape  : Dict<i32, List<BattlefieldStack>>
  .CardBounds      : { m_Height, m_Width, m_XMin, m_YMin } (f32)

BattlefieldStack
  .AllCards         : List<BaseCDC>     ← cards in this stack
  .AttachmentCount  : i32
  .CardCount        : i32
  .ExileCount       : i32
  .IsAttackStack    : bool
  .IsBlockStack     : bool
```

For "what cards has the opponent revealed" the minimum traversal is:

1. Battlefield → opponent regions → stacks → `AllCards`
2. `(Opponent, Graveyard) → _previousLayoutData`
3. `(Opponent, Exile) → _previousLayoutData`
4. `(Opponent, Stack) → _previousLayoutData`
5. `(Opponent, Command) → _previousLayoutData`
6. `(Opponent, Hand) → _previousLayoutData` filtered to entries with
   `IsVisibleInLayout = true` and no `FaceDownState` — i.e. revealed-
   in-hand cards (Thoughtseize, Duress, etc.).

Library is opaque — the client never has unrevealed identities; its
holder will have entries with face-down state set and no `BaseGrpId`.

Sources:
- `ScryIpcHandler-x0rjOwCx/src/scry/readers/mtga/ScryMtgaMatchReader.ts`
- `ScryIpcHandler-x0rjOwCx/src/scry/utils/types/mtga/MatchSceneManager.ts`
- `ScryIpcHandler-x0rjOwCx/src/scry/utils/mtga/ScryBattlefieldStacks.ts`
- `ScryIpcHandler-x0rjOwCx/src/scry/utils/mtga/ScryMatchZone.ts`

### Chain 3 — active events (entry, wins/losses, in-flight state) — VERIFIED 2026-05-06

Anchored at the same `PAPA._instance` static the other chains use.
Provides the player's full list of available + in-progress event
entries — the data behind the dashboard's "Active events" / "4-1
in Premier Draft" surface.

Verified live against MTGA build timestamp `Fri Apr 11 17:22:20 2025`.
52 EventContexts observed; entry [12] (`DualColorPrecons`) read
22W-17L matching MTGA's UI exactly. See
[`spike21_active_events/FINDING.md`](../../../../mtga-duress/experiments/spikes/spike21_active_events/FINDING.md)
for full evidence.

**Tear-down behaviour:** `EventManager` and the `EventContexts` list
persist across match boundaries — unlike `MatchSceneManager.Instance`
(Chain 2) and `MatchManager.LocalPlayerInfo`/`OpponentInfo` (Chain 1
post-match), this chain is safe to read at any time after MTGA
finishes loading. Pre-login, `PAPA._instance.EventManager` is null.

**PAPA → EventManager** (same anchor as Chain 1):

| Offset | Field | Notes |
|---:|---|---|
| `0x0110` | `<EventManager>k__BackingField` | instance, attrs `0x0001` — verified by spike20 PAPA manifest *and* spike21 |

**EventManager class** (9 instance fields):

| Offset | Field | Notes |
|---:|---|---|
| `0x0010` | `_eventsServiceWrapper` | `AwsEventServiceWrapper` (network) |
| `0x0018` | `_accountClient` | `WizardsAccountsClient` |
| `0x0028` | `_cardDatabase` | `CardDatabase` (shared with other chains) |
| **`0x0030`** | **`<EventContexts>k__BackingField`** | **`List<EventContext>` — primary collection** |
| `0x0038` | `<DynamicFilterTags>k__BackingField` | `List<ClientDynamicFilterTag>` (Play-screen filter chips) |
| `0x0040` | `<EventsByInternalName>k__BackingField` | `Dictionary` — empty in steady state |
| `0x0048` | `_lastEventContextRefresh` | timestamp |

**EventContext** (3 instance fields):

| Offset | Field | Notes |
|---:|---|---|
| `0x0010` | `PlayerEvent` | polymorphic — `BasicPlayerEvent` or `LimitedPlayerEvent` |
| `0x0018` | `PostMatchContext` | null unless event just completed (transient) |
| `0x0020` | `DeckSelectContext` | null unless in deck-select state (transient) |

**BasicPlayerEvent** (parent class — 9 instance fields, 1 static skipped):

| Offset | Field | Notes |
|---:|---|---|
| `0x0010` | `<EventInfo>k__BackingField` | `BasicEventInfo` |
| `0x0018` | `<EventUXInfo>k__BackingField` | |
| `0x0020` | `<Format>k__BackingField` | `DeckFormat` (NULL on `LimitedPlayerEvent` — format derived from draft pool) |
| `0x0028` | `<CourseData>k__BackingField` | public-API mirror with `CurrentEventState`/`CurrentModule` ints |
| **`0x0038`** | **`_courseInfo`** | **private — `AwsCourseInfo` wrapper around the wire-format course mirror** |
| `0x0040` | `_eventsServiceWrapper` | (private) |

**LimitedPlayerEvent : BasicPlayerEvent** adds one field:

| Offset | Field | Notes |
|---:|---|---|
| `0x0058` | `<DraftPod>k__BackingField` | `DraftPod` — populated only while a draft is in progress |

**CourseData** (9 instance fields — public state, used to discriminate entries):

| Offset | Field | Notes |
|---:|---|---|
| `0x0040` | `Id` | course id (string) |
| **`0x0050`** | **`CurrentEventState`** | **i32 — see "State enum values" below** |
| `0x0054` | `CurrentModule` | i32 — round/stage pointer |
| `0x0030` | `DraftId` | string id (limited only) |
| `0x0038` | `MadeChoice` | bool? (deck choice flag) |

**`AwsCourseInfo`** (1 instance field):

| Offset | Field | Notes |
|---:|---|---|
| `0x0010` | `_clientPlayerCourse` | `ClientPlayerCourseV3` — the wire-format mirror |

**`ClientPlayerCourseV3`** (15 instance fields — primary state holder, where wins/losses live):

| Offset | Field | Type | Notes |
|---:|---|---|---|
| `0x0010` | `InternalEventName` | MonoString | duplicates `EventInfoV3.InternalEventName` |
| `0x0018` | `ModulePayload` | MonoString | empty in observed entries |
| `0x0020` | `CourseDeckSummary` | `DTO_DeckSummaryV3 *` | name, mana cost summary, deck-art |
| `0x0028` | `CourseDeck` | `Deck *` | submitted deck (`MainDeck`, `Sideboard`, `CommandZone`, `Companions`) |
| `0x0030` | `CardPool` | `List<???>` | drafted cards (limited) |
| `0x0050` | `DraftId` | MonoString | |
| `0x0058` | `TournamentId` | MonoString | |
| `0x0060` | `MadeChoice` | MonoString | course-instance UUID set when player picks event deck (despite the name, NOT a bool) |
| `0x0068` | `CourseId` | MonoString | |
| **`0x0078`** | **`CurrentModule`** | **i32** | round/module pointer (mirrors `CourseData.CurrentModule`) |
| **`0x007c`** | **`CurrentWins`** | **i32** | win count for this entry |
| **`0x0080`** | **`CurrentLosses`** | **i32** | loss count for this entry |

**`BasicEventInfo`** (2 instance fields):

| Offset | Field | Notes |
|---:|---|---|
| `0x0010` | `<EntryFees>k__BackingField` | `List<???>` — entry tokens / gems |
| `0x0018` | `_eventInfoV3` | `EventInfoV3` — canonical wire-format event-template metadata |

**`EventInfoV3`** (14 instance fields — event-template metadata, not per-player progress):

| Offset | Field | Notes |
|---:|---|---|
| `0x0010` | `InternalEventName` | MonoString — e.g. `Premier_Draft_DFT` |
| `0x0018` | `Flags` | bitfield |
| `0x0020` | `PastEntries` | `List<???>` — empty in observed entries (server-pushed history?) |
| `0x0028` | `EntryFees` | duplicate of `BasicEventInfo.EntryFees` |
| `0x0030` | `EventTags` | `List<???>` |
| `0x0050` | `EventState` | i32 — `0` = open, `1` = closed/expired, `2` = special |
| `0x0054` | `FormatType` | i32 — `1` = Limited, `2` = Sealed, `3` = Constructed |
| `0x0058` | `StartTime` | DateTime |
| `0x0070` | `WinCondition` | i32 |

**State enum values (CurrentEventState / CurrentModule)** — captured live across 52 entries:

| `CurrentEventState` | `CurrentModule` | Meaning | Examples |
|---:|---:|---|---|
| 0 | 0 | Available — never entered, root entry-point | `ColorChallenge` |
| 0 | 1 | Available — never entered (default) | `ColorChallenge_Node5_*`, `TradDraft_SOS_…`, `Sealed_SOS_…` |
| 1 | 7 | Entered / in progress | `Jump_In_2024`, `QuickDraft_SOS_…`, `DualColorPrecons` |
| 3 | 11 | Standing / always-on (no entry fee) | `Play`, `Constructed_BestOf3`, `Traditional_Ladder`, `Ladder` |

**Walker rule:** an entry is "actively engaged" when
`CurrentEventState != 0`. Wins/losses can still be 0 in an `Entered`
entry (entered but no matches played yet) — the state enum is the
truth, not the counters.

```
PAPA._instance                                       (existing anchor)
  .EventManager
    .EventContexts                              : List<EventContext>
      [i].PlayerEvent
            .EventInfo._eventInfoV3
              .InternalEventName              : string  ("Premier_Draft_DFT")
              .EventState / .FormatType       : i32 enums
              .EntryFees                      : List<entry-fee>
            .CourseData
              .CurrentEventState              : i32 enum (0/1/3 → see table)
              .CurrentModule                  : i32 (1/7/11)
            .Format._formatName               : string ("Standard", null on Limited)
            ._courseInfo._clientPlayerCourse
              .CurrentWins                    : i32
              .CurrentLosses                  : i32
              .CourseDeck                     : Deck
      [i].PostMatchContext  ── transient post-match
      [i].DeckSelectContext ── transient deck-select
```

**Resolution discipline:** every field above must be looked up **by
name** (`field::find_field_by_name` / `_in_chain`). The literal
offsets are reproduced here for documentation and unit-test fixtures
only. Game-class field offsets are not pinned as constants — only
`MonoOffsets` (Mono runtime offsets) are.

Source: this skill block + `mtga-duress/experiments/spikes/spike21_active_events/FINDING.md`.

### Generic types the walker doesn't yet handle

Both chains use Mono `List<T>` (`T[] _items + i32 _size + i32 _version`)
and `Dictionary<K, V>` with non-`int` generic parameters. The current
walker's `dict.rs` is hardcoded to `Dictionary<int, int>` (the
inventory cards collection). Reuse it for the new chains will require
parameterising the value-size and pointer-vs-inline read.

`List<T>` has no walker module yet. It's straightforward — header
fields then dereference `_items` as a Mono `MonoArray<T>` (`obj` +
`bounds` + `max_length` + flex `vector[]` per the existing
`MonoArray` offsets) — but it's a new module nonetheless.

### Research note

Full feasibility analysis, capture-model trade-offs (one-shot at
`MatchCompleted` vs `Scry2.LiveState` polling), and recommended
implementation contour: `decisions/research/2026-04-30-001-opponent-game-state-memory-read.md`.

## Canonical sources

Walker offsets must be confirmed against **at least two independent
sources** before any `#[repr(C)]` or offset constant is pinned in the
Rust crate. The ranked sources are:

1. **Unity-Technologies/mono @ `unity-2022.3-mbe`** (MIT).
   Authoritative struct definitions. Pull the raw file via
   `gh api -H 'Accept: application/vnd.github.raw' 'repos/Unity-Technologies/mono/contents/mono/metadata/<file>?ref=unity-2022.3-mbe'`.
   Key files:
   - `mono/metadata/class-private-definition.h` — `struct _MonoClass`
     (the real definition; `class-internals.h` only forward-declares it)
   - `mono/metadata/class-internals.h` — `struct _MonoClassField`,
     `struct MonoVTable`, `union _MonoClassSizes`, `enum MonoTypeKind`
   - `mono/metadata/class-getters.h` — the full `m_class_offsetof_*`
     macro list; authoritative field-name manifest
   - `mono/metadata/domain-internals.h` — `struct _MonoDomain`
   - `mono/metadata/metadata-internals.h` — `struct _MonoAssembly`,
     `_MonoAssemblyName`, `_MonoImage`
   - `mono/metadata/object-internals.h` — `_MonoArray`, `_MonoString`
2. **Live disassembly of MTGA's `mono-2.0-bdwgc.dll`** (see
   "Disassembly evidence" below). Authoritative for *this specific build*;
   deviates from source only if the build pinned a patch.
3. **Unispect / Unispect-DMA** — AGPL-3.0. Technique and cross-check only;
   **do not copy source**. Useful as a third independent voice when the
   first two disagree.

Conditional-compilation gates that change layout between builds:
`DISABLE_REMOTING`, `DISABLE_COM`, `MONO_SMALL_CONFIG`,
`ENABLE_CHECKED_BUILD_PRIVATE_TYPES`. The Unity MonoBleedingEdge build
has **none** of these defined — every `#ifndef DISABLE_*` branch is
taken. Verify this assumption against any new build before trusting
derived offsets.

## Verified findings (2026-04-25 reading of MTGA build timestamp
`Fri Apr 11 17:22:20 2025`, file size 7,897,520 bytes)

### Export RVAs in `mono-2.0-bdwgc.dll`

| Export | Ordinal | RVA | File offset |
|---|---:|---:|---:|
| `mono_get_root_domain` | 489 | `0x000a71b0` | `0x000a65b0` |
| `mono_assembly_loaded` | 69 | `0x000b6be0` | `0x000b5fe0` |
| `mono_domain_assembly_open` | 301 | `0x000a7e50` | `0x000a7250` |
| `mono_class_vtable` | 183 | `0x001ca860` | `0x001c9c60` |
| `mono_class_get_field_from_name` | 135 | `0x000bd140` | `0x000bc540` |
| `mono_image_loaded` | 526 | `0x0014cdb0` | `0x0014c1b0` |

These are derived from the PE export directory at RVA `0x73be00`.
To re-derive on a newer build, parse the export directory (or use
`native/scry2_collection_reader/src/walker/pe.rs::find_export_rva`).

### `mono_get_root_domain` prologue — validated

First 8 bytes at RVA `0xa71b0`:

```
48 8b 05 69 9e 6a 00  c3
mov  rax, [rip+0x6a9e69]
ret
```

Canonical `mov rax, [rip+disp32]; ret` pattern expected by
`walker/prologue.rs`. Derived static pointer address:

- RIP after mov = `0xa71b0 + 7 = 0xa71b7`
- disp32 = `0x006a9e69`
- `mono_root_domain` static pointer RVA = `0xa71b7 + 0x6a9e69 = 0x746020`

At runtime, `read_u64(mono_base + 0x746020)` yields the live
`MonoDomain *`.

### Disassembly evidence for struct offsets (first-pass, needs confirmation)

Leading bytes of `mono_class_vtable(MonoDomain *domain, MonoClass *class)`:

```
1801ca880  mov  rdi, rdx               ; rdi = class
1801ca888  mov  r14, rcx               ; r14 = domain
   ...safepoint / telemetry prologue...
1801ca954  test dword [rdi+0x28], 0x100000
1801ca95d  mov  rax, qword [rdi+0xe0]
```

- `[rdi+0x28]` read as a 32-bit flags word with `0x100000` likely being
  `MONO_CLASS_IS_ARRAY`-adjacent — suggests the bitfield byte cluster in
  `_MonoClass` around the `inited/valuetype/enumtype/...` group lives
  at offset `0x28`. **First-pass candidate**, not confirmed.
- `[rdi+0xe0]` looks like `MonoClass.runtime_info` (used to find a
  per-domain VTable). **First-pass candidate**, not confirmed.

Leading bytes of `mono_class_get_field_from_name(MonoClass *klass, const char *name)`:

```
1800bd14a  ...
1800bd164  mov  rdi, rcx               ; rdi = klass
1800bd20e  test dword [rdi+0x28], 0x100000
1800bd226  mov  rbx, qword [rdi+0x98]
```

- `[rdi+0x98]` is likely `MonoClass.fields` — the MonoClassField array
  the function iterates. **First-pass candidate**, not confirmed.

### Verified offset table (2026-04-25 reading)

Cross-checked by two independent sources: the `offsets_probe/dump.c`
program (compiled with `gcc -mms-bitfields` against Unity's headers)
and live disassembly of the MTGA DLL. Values marked ✓ agree between
both sources.

**`MonoClass`:**

| Offset | Field | Evidence |
|---:|---|---|
| 0x00 | `element_class` | dumper |
| 0x08 | `cast_class` | dumper |
| 0x10 | `supertypes` | dumper |
| 0x18 | `idepth` (u16) | dumper |
| 0x1a | `rank` (u8) | dumper |
| 0x1b | `class_kind` (u8) | dumper |
| 0x1c | `instance_size` (i32) | dumper |
| 0x20 | bitfield group 1 (`inited`…`is_byreflike`) | dumper |
| 0x24 | `min_align` (u8) | dumper |
| 0x28 | bitfield group 2 (`packing_size`…`has_dim_conflicts`, 23 bits; `has_failure` at bit 20) | ✓ dumper + `test [rdi+0x28], 0x100000` in `mono_class_vtable` |
| 0x30 | `parent` | dumper |
| 0x38 | `nested_in` | dumper |
| 0x40 | `image` | dumper |
| 0x48 | `name` | dumper |
| 0x50 | `name_space` | dumper |
| 0x58 | `type_token` (u32) | dumper |
| 0x5c | `vtable_size` (i32) | dumper |
| 0x60 | `interface_count` (u16) | dumper |
| 0x64 | `interface_id` (u32) | dumper |
| 0x68 | `max_interface_id` (u32) | dumper |
| 0x6c | `interface_offsets_count` (u16) | dumper |
| 0x70 | `interfaces_packed` | dumper |
| 0x78 | `interface_offsets_packed` | dumper |
| 0x80 | `interface_bitmap` | dumper |
| 0x88 | `interfaces` | dumper |
| 0x90 | `sizes` (union, 4 bytes) | dumper |
| 0x98 | `fields` | ✓ dumper + `mov rbx,[rdi+0x98]` in `mono_class_get_field_from_name` |
| 0xa0 | `methods` | dumper |
| 0xa8 | `this_arg` (MonoType, 16 bytes) | dumper |
| 0xb8 | `_byval_arg` (MonoType, 16 bytes) | dumper |
| 0xc8 | `gc_descr` (pointer-sized) | dumper |
| 0xd0 | `runtime_info` | ✓ dumper + `mov rsi,[rdi+0xd0]` in `mono_class_vtable` post-`has_failure`-branch |
| 0xd8 | `vtable` | dumper |
| 0xe0 | `infrequent_data` (`MonoPropertyBag`, 8 bytes) | ✓ dumper + `mov rax,[rdi+0xe0]` in `mono_class_vtable` on-`has_failure` branch |
| 0xe8 | `unity_user_data` | dumper |

Total `sizeof(MonoClass) = 240` (= 0xf0).

**`MonoClassField`** (each entry 32 bytes):

| Offset | Field |
|---:|---|
| 0x00 | `type` (`MonoType *`) |
| 0x08 | `name` (`const char *`) |
| 0x10 | `parent` (`MonoClass *`) |
| 0x18 | `offset` (i32) |

**`MonoVTable`** (base size 80, plus flex trailing `vtable[]`):

| Offset | Field |
|---:|---|
| 0x00 | `klass` |
| 0x08 | `gc_descr` |
| 0x10 | `domain` |
| 0x18 | `type` |
| 0x20 | `interface_bitmap` |
| 0x28 | `max_interface_id` (u32) |
| 0x2c | `rank` (u8) |
| 0x2d | `initialized` (u8) |
| 0x2e | `flags` (u8) |
| 0x34 | `imt_collisions_bitmap` (u32) |
| 0x38 | `runtime_generic_context` |
| 0x40 | `interp_vtable` |
| **0x48** | **`vtable[0]` — start of static storage / method trampolines** |

`vtable->data[offset]` reads (for STATIC-flagged fields) land at
`vtable_base + 0x48 + offset`. This is the address the walker uses to
read `PAPA.<Instance>k__BackingField`.

**`MonoObject`** (16 bytes):

| Offset | Field |
|---:|---|
| 0x00 | `vtable` |
| 0x08 | `synchronisation` |

**`MonoArray`** (32 bytes fixed + flex trailing `vector[]`):

| Offset | Field |
|---:|---|
| 0x00 | `obj` (MonoObject) |
| 0x10 | `bounds` |
| 0x18 | `max_length` (uintptr_t) |
| **0x20** | **`vector[0]` — start of element storage** |

**`MonoDomain`:**

| Offset | Field | Evidence |
|---:|---|---|
| 0x90 | `state` (u32) | `cmp DWORD PTR [rcx+0x90], 0x3` in `mono_domain_assembly_open_internal` (rcx = domain) |
| 0x94 | `domain_id` (i32) | `movsxd rcx,[r14+0x94]` in `mono_class_vtable` fast path (`r14` = domain param) |
| 0x98 | `shadow_serial` (i32) | source order — `gint32` immediately after `domain_id` per `domain-internals.h` |
| 0xa0 | `domain_assemblies` (GSList *) | ✓ source order (8-byte aligned after `shadow_serial`) + `mov r14,[r13+0xa0]; mov rsi,[r14]; mov r14,[r14+0x8]` GSList loop in `mono_domain_assembly_open_internal` (loop at `1800a8219..1800a828d`) |

Class-VTable hash and other `MonoDomain` fields are still TBD — those
land when the walker stops needing the assembly walk and switches to
`class_vtable_hash` for class lookup.

**`GSList`** (mono/eglib singly linked list, 16 bytes):

| Offset | Field |
|---:|---|
| 0x00 | `data` (gpointer) |
| 0x08 | `next` (`GSList *`) |

✓ dumper + live disassembly: `mov rsi,[r14]` (data) and
`mov r14,[r14+0x8]` (next) form the GSList loop in
`mono_domain_assembly_open_internal`.

**`MonoAssemblyName`** (80 bytes, ENABLE_NETCORE off in MBE so `major`/
`minor`/`build`/`revision`/`arch` are u16):

| Offset | Field |
|---:|---|
| 0x00 | `name` (`const char *`) |
| 0x08 | `culture` (`const char *`) |
| 0x10 | `hash_value` (`const char *`) |
| 0x18 | `public_key` (`const mono_byte *`) |
| 0x20 | `public_key_token[17]` |
| 0x34 | `hash_alg` (u32) |
| 0x38 | `hash_len` (u32) |
| 0x3c | `flags` (u32) |
| 0x40 | `major`/`minor`/`build`/`revision`/`arch` (5 × u16) |

**`MonoAssembly`** (truncated to `image` — fields beyond not consumed):

| Offset | Field | Evidence |
|---:|---|---|
| 0x00 | `ref_count` (i32) | dumper |
| 0x08 | `basedir` (char *) | dumper |
| 0x10 | `aname` (`MonoAssemblyName`, embedded) — first field is `aname.name` so `[asm+0x10]` IS the name pointer | ✓ dumper + `mov rax,[rbx+0x10]` reading the assembly name in `mono_domain_assembly_open_internal` (rbx = assembly) |
| 0x60 | `image` (`MonoImage *`) | ✓ dumper + `mov rsi,[rsi+0x60]` reading the image pointer right after dereferencing the GSList data slot |

**`MonoImage`** (truncated to `class_cache`):

| Offset | Field |
|---:|---|
| 0x00 | `ref_count` (int) |
| 0x08 | `storage` (`MonoImageStorage *`) |
| 0x10 | `raw_data` (char *) |
| 0x18 | `raw_data_len` (u32) |
| 0x20 | `name` (char *) |
| 0x28 | `filename` (char *) |
| 0x30 | `assembly_name` (`const char *`) |
| 0x38 | `module_name` (`const char *`) |
| 0x4c0 | `assembly` (`MonoAssembly *`) |
| 0x4c8 | `method_cache` (`GHashTable *`) |
| **0x4d0** | **`class_cache` (`MonoInternalHashTable`, embedded by value)** |

✓ dumper for the full prefix; live disassembly confirms `class_cache`
via `lea rcx, [r13+0x4d0]; call mono_internal_hash_table_lookup` at
`1800c83b3..1800c83bc`.

The intermediate offsets between `module_name` and `assembly` are
controlled by the embedded `MonoStreamHeader heap_*` (6 × 16 bytes),
the `MonoTableInfo tables[MONO_TABLE_NUM]` array (56 × 16 bytes), and
several pointer fields. Re-derive from the dumper if you need them.

**`MonoInternalHashTable`** (40 bytes, embedded in `MonoImage.class_cache`):

| Offset | Field | Evidence |
|---:|---|---|
| 0x00 | `hash_func` (`GHashFunc` — function pointer) | ✓ dumper + `call QWORD PTR [rdi]` in `mono_internal_hash_table_lookup` |
| 0x08 | `key_extract` (function pointer) | ✓ dumper + `call QWORD PTR [rdi+0x8]` |
| 0x10 | `next_value` (function pointer) | ✓ dumper + `call QWORD PTR [rdi+0x10]` |
| 0x18 | `size` (i32 — bucket count) | ✓ dumper + `div DWORD PTR [rdi+0x18]` |
| 0x1c | `num_entries` (i32) | dumper (source order between `size` and `table`; both gint with no padding) |
| 0x20 | `table` (`gpointer *` — heap-allocated array of `size` chain heads) | ✓ dumper + `mov rbx, [rdi+0x20]` |

For class_cache iteration the walker bypasses the function-pointer
callbacks (we can't invoke remote function pointers) and walks
`MonoClassDef.next_class_cache = 0x108` directly. Each chain entry is
a `MonoClassDef *` whose embedded `MonoClass` lives at offset 0; its
name (offset 0x48) and `class_kind` (offset 0x1b) are already in
`MonoOffsets`.

**`MonoClassDef.next_class_cache`** (chain pointer for `class_cache`
buckets): offset `0x108` per dumper. Stored as `MonoClass *` in the
header but always points to the next `MonoClassDef *` in the bucket.

**`MonoClassRuntimeInfo`** (inferred from `mono_class_vtable` fast path):

| Offset | Field |
|---:|---|
| 0x00 | `max_domain` (u16) |
| 0x08 | `domain_vtables[N]` (array of pointers, indexed by `domain_id`) |

### The disagreement that is now resolved

Earlier sessions flagged a `0xd0 vs 0xe0` disagreement on
`runtime_info`. Root cause: the disassembly I initially eyeballed as
the runtime_info load was actually on the `has_failure` branch, where
`[rdi+0xe0]` reads `infrequent_data` (the property bag used to fetch
the failure's exception data). The real runtime_info load is at
`[rdi+0xd0]` on the non-failure branch. Both the dumper and the live
disassembly now agree: `runtime_info = 0xd0`. The earlier
interpretation error was mine, not a build-layout anomaly.

### Walker code in sync

`native/scry2_collection_reader/src/walker/mono.rs`'s
`MonoOffsets::mtga_default()` pins `class_fields=0x98`,
`class_runtime_info=0xd0`, `class_flags_cluster=0x28` — all verified.
The module's unit tests (43 across the crate) exercise every accessor
against synthetic byte buffers. No live-memory reads yet; those land
when `field.rs` / `dict.rs` / `inventory.rs` are wired up.

## Struct offsets — open work

The walker's `mono.rs` module pins offsets verified by both the
`offsets_probe/` dumper and live disassembly. All offsets required by
`class_lookup`, `image_lookup`, and the existing inventory walk are
now in. The next walker module (`domain.rs`) needs no new struct
offsets — it composes existing pieces (`pe`, `prologue`,
`mono_get_root_domain`).

### Method for each offset

For each field:
1. Locate the field in the Unity header (`class-private-definition.h`
   or equivalent).
2. Count bytes from the top of the struct, respecting:
   - Pointer alignment (8 bytes on x86-64)
   - Bitfield packing (Windows `MSVC` ABI differs from Itanium/SysV —
     the MonoBleedingEdge Windows DLL uses MSVC bitfield rules)
   - `#ifdef` branches taken (see "Conditional-compilation gates" above)
3. Pick a Mono function that reads or computes with the field.
4. Disassemble it against MTGA's live bytes (see "Disassembly evidence"
   pattern above) to confirm the literal offset matches.
5. If the two agree, pin in `mono.rs`. If they diverge, widen the
   investigation — do not ship a guess.

### Disassembly recipe

```bash
DLL=/home/shawn/.local/share/Steam/steamapps/common/MTGA/MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll
# find the export:
objdump -p "$DLL" | grep -E '^\s+\[.*<symbol_name>'
# parse the export table yourself, or use walker/pe.rs::find_export_rva.
# then disassemble (VA = 0x180000000 + RVA):
objdump -d --disassembler-options=intel --start-address=<VA> --stop-address=<VA+N> "$DLL"
```

## Read budget — operational knob

Every NIF wraps its `process_vm_readv` closure in
[`read_budget::bounded`](../../../native/scry2_collection_reader/src/read_budget.rs)
to cap one walk at `WALK_READ_BUDGET` reads. The cap exists to stop
runaway walks (PID reuse against an unrelated process; self-
referential pointer loops on partially-zeroed memory) from pegging
a dirty-IO scheduler thread.

**The cap is load-bearing.** Past the limit every read returns `None`
and the walker silently bails as if the chain were broken — typically
surfacing as `WalkError::ClassNotFound("PAPA")` because PAPA discovery
is the first big read-burner.

Measured against MTGA build `Fri Apr 11 17:22:20 2025` (222 loaded
Mono images), a single walk costs:

| Walker | reads_used |
|---|---:|
| `walk_match_info` (Chain-1) | ~69,000 |
| `walk_match_board` (Chain-2) | ~64,000 |

Both chains scale with the image count, since `find_class_in_images`
iterates every image looking for the target class. Class lookup
within an image walks the class hash buckets (cost ~ O(classes per
image)).

Current cap: **200,000 reads** (set v0.30.3, ~3× headroom over
measured cost). When MTGA grows further:

1. Use `walker_debug_walk_match_info_with_stats(pid)` /
   `walker_debug_walk_match_board_with_stats(pid)` (NIFs in
   `Scry2.MtgaMemory.Nif`) to read live `reads_used` against the
   running process. Both return `(result, %{reads_used, budget})`.
2. The Settings → Memory reading "Run diagnostic capture now" button
   surfaces these inline.
3. If `reads_used` creeps above 70% of budget, raise the cap (and
   document the new measurement in this section).

The structural fix is to cache discovery results
(`PAPA`, `MatchSceneManager`, runtime class addresses) per
`(pid, mono_base)`, dropping the steady-state cost from "scan 222
images" to "follow 5 pointers" (a few hundred reads). v0.31.0 adds
that cache; until then, the budget is the load-bearing defense.

Full diagnostic procedure and evidence:
[`spike19_read_budget_regression/FINDING.md`](../../../../mtga-duress/experiments/spikes/spike19_read_budget_regression/FINDING.md).

## Sibling module: the POC

`mtga-duress/experiments/mtga-reader-poc/` — working structural-scan
implementation. 4,091 cards recovered on the research machine in ~1.4s.
Does not use any Mono offsets. Value: its address-discovery and
`process_vm_readv`-based read primitives are a reference for how the
production crate handles memory access, even though the walker uses a
completely different locator strategy.

## Related scry_2 artifacts

- `native/scry2_collection_reader/src/walker/prologue.rs` — parses
  `mov rax, [rip+disp32]; ret` (validated against `mono_get_root_domain`
  above).
- `native/scry2_collection_reader/src/walker/pe.rs` — finds a named
  export in a mapped PE32+ image (used before `prologue.rs` runs).
- `decisions/architecture/2026-04-22-034-memory-read-collection.md` —
  ADR for the overall reader, including the walker-in-Rust decision
  (Revision 2026-04-25). Decision document, not a protocol reference —
  details live here.
- `plans.md` — "Currently in progress — Walker phase 6 (Rust)" tracks
  module status.
- `mtga-duress/experiments/spikes/spike{5,6,7,10}/FINDING.md` — prior
  research.
