defmodule Scry2.Events.IdentifyDomainEvents do
  @moduledoc """
  Pipeline stage 07 — the anti-corruption layer between MTGA's wire
  format and scry_2's domain model (ADR-018).

  ## Contract

  | | |
  |---|---|
  | **Input**  | `%Scry2.MtgaLogIngestion.EventRecord{}` + `self_user_id` (nil for seat-1 fallback) |
  | **Output** | List of domain event structs (`%Scry2.Events.*{}`); empty list if nothing applies |
  | **Nature** | Pure — no DB, no GenServer, no side effects |
  | **Called from** | `Scry2.Events.IngestRawEvents` |
  | **Hands off to** | `Scry2.Events.append!/2` (persists + broadcasts each struct) |

  ## The ACL principle

  IdentifyDomainEvents is the **only** module in scry_2 that understands
  MTGA's wire format. Every other module — projectors, LiveViews,
  analytics, anything downstream — works with typed domain event
  structs and is insulated from MTGA protocol changes. When MTGA
  reshuffles a nested JSON field or renames an event type, this file
  is the single place that changes.

  Function head pattern matching dispatches on the raw MTGA event
  type. Each clause decodes the payload, extracts the relevant fields,
  and builds zero or more domain event structs. A single MTGA event
  can produce multiple domain events (e.g. a `GreToClientEvent`
  carrying a `connectResp` AND a `GameStateMessage` would produce both
  a `%DeckSubmitted{}` and a `%GameStateChanged{}`).

  ## Naming rule

  MTGA event type names (`MatchGameRoomStateChangedEvent`) never leak
  past this module. Every public identifier on the output side uses
  scry_2's domain vocabulary (`MatchCreated`, `MatchCompleted`). If
  you find yourself grepping for `MatchGameRoomStateChangedEvent` in
  a projector or LiveView, that's a bug.

  ## Adding a new event type

  1. Define a `%Scry2.Events.Foo{}` struct in `lib/scry_2/events/foo.ex`
     with `Scry2.Events.Event` protocol impl.
  2. Add a `translate/2` clause here that consumes the relevant raw
     MTGA event type and produces the struct.
  3. Add a projector handler in whichever context owns the projection.

  See `TODO.md` > "Match ingestion follow-ups" for the backlog of
  event types waiting to be added.

  ## MTGA protocol pitfalls (learned the hard way)

  These are non-obvious behaviors in MTGA's wire format that caused
  data corruption before being understood and handled:

  ### Player seat is NOT always 1

  The player alternates between seat 1 and seat 2 across matches.
  `MatchGameRoomStateChangedEvent` carries `reservedPlayers[]` with
  `userId` → `systemSeatId` mapping, so we can find the player
  correctly. But `GreToClientEvent` (GRE messages) has no
  `reservedPlayers`. Instead, each GRE message's `systemSeatIds`
  field tells us which seat the message is addressed to. Since
  `GreToClientEvent` is the player's client feed, `systemSeatIds[0]`
  IS the player's seat number.

  **Perspective is resolved once per GRE batch** via
  `resolve_player_seat/1` and threaded as `player_seat` to all
  perspective-sensitive sub-handlers (DeckSubmitted, DieRolled,
  GameCompleted). No handler determines perspective independently.
  For `ClientToGremessage` events (e.g. StartingPlayerChosen), the
  player's seat comes from `match_context[:self_seat_id]`, established
  by the ConnectResp that produced the earlier DeckSubmitted.

  ### GRE game results are wrong for conceded games

  When a player concedes, the GRE's `GameStateMessage` with
  `MatchState_GameComplete` reports the last game state before the
  concession — showing the conceding player as "winning" that game.
  The matchmaking layer's `finalMatchResult.resultList[]` (in
  `MatchGameRoomStateChangedEvent`) is authoritative. The translation
  layer cannot correct `GameCompleted.won` because the authoritative
  source (`MatchCompleted`) arrives in a later event. Correction
  happens at the projection level: both `MatchProjection` and
  `DeckProjection` correct per-game `won` values using
  `MatchCompleted.game_results`. See `GameCompleted` and
  `MatchCompleted` @moduledocs for details.

  ### Deck format gets overwritten by event type

  MTGA's `DeckUpsertDeckV2` sets the `Format` attribute to event-type
  strings like `"DirectGame"` or `"DirectGameLimited"` when a deck is
  used in direct challenges. This overwrites the actual format
  (`"Standard"`, `"Historic"`). We filter these via
  `normalize_deck_format/1` against a whitelist of known formats.

  ### Team IDs differ between GRE and matchmaking

  The `teamId` values in `GameStateMessage.players[]` may use
  different numbering than `reservedPlayers[].teamId`. Don't compare
  team IDs across these two message types. Within each message type,
  team IDs are internally consistent.
  """

  alias Scry2.Events.Deck.{DeckInventory, DeckSelected, DeckSubmitted, DeckUpdated}
  alias Scry2.Events.EventName

  alias Scry2.Events.IdentifyDomainEvents.{
    ClientToGre,
    ConnectResp,
    GameStateMessage,
    Helpers,
    MatchRoom
  }

  alias Scry2.Events.Draft.{
    DraftCompleted,
    DraftPickMade,
    DraftStarted,
    HumanDraftPackOffered,
    HumanDraftPickMade
  }

  alias Scry2.Events.Economy.{
    CollectionUpdated,
    InventoryChanged,
    InventorySnapshot,
    InventoryUpdated
  }

  alias Scry2.Events.Event.{
    EventCourseUpdated,
    EventJoined,
    EventRewardClaimed,
    PairingEntered
  }

  alias Scry2.Events.Progression.{DailyWinsStatus, MasteryProgress, QuestStatus, RankSnapshot}
  alias Scry2.Events.Session.{SessionDisconnected, SessionStarted}
  alias Scry2.Events.TranslationWarning

  alias Scry2.MtgaLogIngestion.EventRecord

  # GREMessageType_QueuedGameStateMessage has the same payload shape
  # as GREMessageType_GameStateMessage. Both carry gameStateMessage.

  # ── Event type registry (ADR-020) ──────────────────────────────────
  #
  # Every raw MTGA event type must be either handled (produces domain
  # events) or explicitly ignored (known but uninteresting). Types not
  # in either set are "unrecognized" and surfaced in the dashboard.

  @handled_event_types MapSet.new([
                         "MatchGameRoomStateChangedEvent",
                         "GreToClientEvent",
                         # Client → GRE game actions (concede, mulligan response, play/draw choice)
                         "ClientToGremessage",
                         "BotDraftDraftPick",
                         "BotDraftDraftStatus",
                         # Human draft events (Premier Draft, Traditional Draft)
                         "Draft.Notify",
                         "EventPlayerDraftMakePick",
                         "DraftCompleteDraft",
                         "AuthenticateResponse",
                         "RankGetSeasonAndRankDetails",
                         "RankGetCombinedRankInfo",
                         # Event participation + economy
                         "EventJoin",
                         "EventClaimPrize",
                         "EventEnterPairing",
                         # Deck management
                         "EventSetDeckV2",
                         "EventSetDeckV3",
                         "DeckGetDeckSummariesV2",
                         "DeckUpsertDeckV2",
                         "DeckUpsertDeckV3",
                         # Progress tracking
                         "QuestGetQuests",
                         "PeriodicRewardsGetStatus",
                         "EventGetCoursesV2",
                         "GraphGetGraphState",
                         # Client startup lifecycle — inventory snapshot on login
                         "StartHook",
                         # Session disconnect — player disconnected from MTGA servers
                         "FrontDoorConnection.Close",
                         # Economy — standalone inventory and collection snapshots
                         "PlayerInventory.GetPlayerCardsV3",
                         "DTO_InventoryInfo"
                       ])

  @ignored_event_types MapSet.new([
                         # GRE client UI messages — animation/display input, no domain semantics
                         "ClientToGreuimessage",
                         # Connection lifecycle — internal MTGA networking plumbing
                         "Client.TcpConnection.Close",
                         "GREConnection.HandleWebSocketClosed",
                         "Connecting",
                         # Legacy login detection — AuthenticateResponse is the primary handler
                         "Client.Connected",
                         # Internal state machine transitions — no domain semantics
                         "Fetching",
                         "Process",
                         "Got",
                         "GeneralStore",
                         # Parser artifact — MatchGameRoomStateChangedEvent logged
                         # without the UnityCrossThreadLogger prefix by a different
                         # code path; the payload is a duplicate of the real event.
                         "STATE",
                         # Deck deletion confirmation — no analytics value
                         "DeckDeleteDeck",
                         # Format catalogue — static reference data, not player activity
                         "GetFormats",
                         # Startup reconnection probe — always empty in normal sessions;
                         # real match data flows through MatchGameRoomStateChangedEvent
                         "EventGetActiveMatches",
                         # Preconstructed deck catalogue — static reference data, not player activity
                         "DeckGetAllPreconDecksV3",
                         # Deck summaries listing — static reference data, not player activity
                         "DeckGetDeckSummariesV3"
                       ])

  @deferred_event_types MapSet.new([])

  @known_event_types @handled_event_types
                     |> MapSet.union(@ignored_event_types)
                     |> MapSet.union(@deferred_event_types)

  @doc "Returns the set of all recognized raw MTGA event types."
  @spec known_event_types() :: MapSet.t(String.t())
  def known_event_types, do: MapSet.new(@known_event_types)

  @doc "Returns the set of event types deferred pending a non-empty payload."
  @spec deferred_event_types() :: MapSet.t(String.t())
  def deferred_event_types, do: MapSet.new(@deferred_event_types)

  @doc "Returns true if the event type has an explicit handler or ignore clause."
  @spec recognized?(String.t()) :: boolean()
  def recognized?(event_type), do: MapSet.member?(@known_event_types, event_type)

  @type self_user_id :: String.t() | nil

  @type match_context :: %{
          optional(:current_match_id) => String.t() | nil,
          optional(:current_game_number) => non_neg_integer() | nil,
          optional(:self_seat_id) => non_neg_integer() | nil,
          optional(:game_objects) => %{optional(integer()) => integer()}
        }

  @doc """
  Translates a raw MTGA event record into a (possibly empty) list of
  domain event structs.

  `self_user_id` is the user's MTGA Wizards ID, used to distinguish
  self from opponent in `reservedPlayers[]`. When nil, the translator
  falls back to assuming `systemSeatId: 1` is the local player.

  `match_context` carries the current match/game state from
  IngestRawEvents (ADR-022), used to tag in-game events like
  mulligans with their match ID.
  """
  @spec translate(%EventRecord{}, self_user_id(), match_context()) ::
          {[struct()], [TranslationWarning.t()]}
  def translate(record, self_user_id, match_context \\ %{})

  # MatchGameRoomStateChangedEvent produces different domain events based
  # on the nested stateType. Playing = match just created. MatchCompleted
  # = match just finished. Other stateTypes (Connected, ConnectingToGRE,
  # etc.) produce no domain events.
  def translate(
        %EventRecord{event_type: "MatchGameRoomStateChangedEvent"} = record,
        self_user_id,
        match_context
      ) do
    MatchRoom.translate(record, self_user_id, match_context)
  end

  # GreToClientEvent carries GRE messages in a nested array. A single
  # raw event can produce multiple domain events — e.g. a ConnectResp
  # (deck submission), a DieRollResultsResp, a GameStateMessage (game
  # completion), and/or MulliganReq messages in the same batch.
  def translate(
        %EventRecord{event_type: "GreToClientEvent"} = record,
        _self_user_id,
        match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         messages when is_list(messages) <-
           get_in(payload, ["greToClientEvent", "greToClientMessages"]) do
      match_id = Helpers.extract_match_id(messages)
      context_match_id = match_id || match_context[:current_match_id]

      # Resolve the player's seat once for the entire GRE batch.
      # Every message in a GreToClientEvent is sent to this player's client.
      # Messages addressed to a single seat (ConnectResp, GameStateMessage)
      # identify the player's seat; broadcast messages (DieRollResultsResp)
      # are addressed to all seats. See "MTGA protocol pitfalls" in @moduledoc.
      player_seat = Helpers.resolve_player_seat(messages)

      # GreToClientEvent is a container that wraps multiple GRE message types.
      # We decode the outer envelope once and pass the inner `messages` list to
      # both sub-translators. ConnectResp and GameStateMessage use build/5 (pre-decoded
      # data) rather than translate/3 (raw EventRecord) for this reason — the envelope
      # is shared, so decoding must happen at this level.
      connect_resp_events =
        ConnectResp.build(messages, context_match_id, occurred_at, player_seat, match_context)

      # When ConnectResp produces a DeckSubmitted, game_number will be incremented
      # by apply_event *after* this batch is processed. Anticipate the increment so
      # GameStateMessage events in the same batch get the correct game_number rather
      # than the stale (pre-increment) value from match_context.
      game_state_context =
        if Enum.any?(connect_resp_events, &is_struct(&1, DeckSubmitted)) do
          Map.put(
            match_context,
            :current_game_number,
            (match_context[:current_game_number] || 0) + 1
          )
        else
          match_context
        end

      game_state_events =
        GameStateMessage.build(
          messages,
          context_match_id,
          occurred_at,
          player_seat,
          game_state_context
        )

      events =
        List.flatten([connect_resp_events, game_state_events])
        |> Enum.reject(&is_nil/1)

      {events, []}
    else
      _ ->
        # Misrouted payload (e.g., ClientToMatchServiceMessage logged under
        # GreToClientEvent header). Skip silently — raw event is preserved.
        {[], []}
    end
  end

  # ClientToGremessage carries the player's in-game actions. Most are
  # high-volume UI responses (PerformActionResp, SelectTargetsResp) that
  # we skip. We extract only high-signal decisions: concede, mulligan
  # response, and play/draw choice.
  def translate(
        %EventRecord{event_type: "ClientToGremessage"} = record,
        self_user_id,
        match_context
      ) do
    ClientToGre.translate(record, self_user_id, match_context)
  end

  # BotDraftDraftStatus has two wire formats (request ==> and response <==).
  # The request carries a double-encoded JSON `request` string with the
  # EventName (format identifier like "QuickDraft_FDN_20260323").
  # The response carries a "Payload" with the initial 14-card pack for pick 1.
  def translate(
        %EventRecord{event_type: "BotDraftDraftStatus"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         {:ok, request} <- decode_request_field(payload) do
      event_name = request["EventName"]
      set_code = EventName.parse(event_name).set_code

      {[
         %DraftStarted{
           mtga_draft_id: event_name,
           event_name: event_name,
           set_code: set_code,
           occurred_at: occurred_at
         }
       ], []}
    else
      _ ->
        case Jason.decode(record.raw_json) do
          {:ok, %{"Payload" => _}} ->
            translate_bot_pack_response(record)

          _ ->
            {[],
             [
               %TranslationWarning{
                 category: :payload_extraction_failed,
                 raw_event_id: record.id,
                 event_type: record.event_type,
                 detail: "failed to decode/extract draft status request"
               }
             ]}
        end
    end
  end

  # BotDraftDraftPick has two wire formats:
  #   Request (==>) — {"id", "request": "{\"PickInfo\": ...}"} — the pick itself
  #   Response (<==) — {"CurrentModule", "Payload": "{\"DraftPack\": ...}"} — server ack
  #
  # The response carries the pack for the NEXT pick (DraftPack with N-1 cards remaining
  # after the picked card was removed). Emitting HumanDraftPackOffered from the response
  # guarantees the pack data is in the event store before DraftPickMade for that pick.
  def translate(
        %EventRecord{event_type: "BotDraftDraftPick"} = record,
        _self_user_id,
        _match_context
      ) do
    with {:ok, payload} <- Jason.decode(record.raw_json),
         {:ok, request} <- decode_request_field(payload) do
      translate_draft_pick_request(request, record)
    else
      _ ->
        case Jason.decode(record.raw_json) do
          {:ok, %{"Payload" => _}} -> translate_bot_pack_response(record)
          _ -> draft_pick_warning(record)
        end
    end
  end

  # ── Human draft events ────────────────────────────────────────────
  #
  # Premier Draft and Traditional Draft use a different set of wire
  # events than bot draft. Pack presentation and pick selection are
  # separate events (vs bot draft where they're bundled).

  # Draft.Notify presents the current pack to the player. PackCards
  # arrives as a comma-separated string of arena_ids. Entries with a
  # "method" key are RPC metadata, not pack data — skip them.
  def translate(
        %EventRecord{event_type: "Draft.Notify"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         false <- Map.has_key?(payload, "method"),
         draft_id when is_binary(draft_id) <- payload["draftId"],
         pack_cards when is_binary(pack_cards) <- payload["PackCards"] do
      arena_ids =
        pack_cards
        |> String.split(",", trim: true)
        |> Enum.map(&String.to_integer(String.trim(&1)))

      {[
         %HumanDraftPackOffered{
           mtga_draft_id: draft_id,
           pack_number: payload["SelfPack"],
           pick_number: payload["SelfPick"],
           pack_arena_ids: arena_ids,
           occurred_at: occurred_at
         }
       ], []}
    else
      true -> {[], []}
      _ -> {[], translation_warning(record, "failed to decode Draft.Notify payload")}
    end
  end

  # EventPlayerDraftMakePick confirms the player's pick in a human draft.
  # GrpIds is an array — Pick Two Draft can have multiple selections.
  def translate(
        %EventRecord{event_type: "EventPlayerDraftMakePick"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         false <- Map.has_key?(payload, "request"),
         grp_ids when is_list(grp_ids) <- payload["GrpIds"],
         draft_id when is_binary(draft_id) <- payload["DraftId"] do
      {[
         %HumanDraftPickMade{
           mtga_draft_id: draft_id,
           pack_number: payload["Pack"],
           pick_number: payload["Pick"],
           picked_arena_ids: grp_ids,
           occurred_at: occurred_at
         }
       ], []}
    else
      true -> {[], []}
      _ -> {[], translation_warning(record, "failed to decode EventPlayerDraftMakePick payload")}
    end
  end

  # DraftCompleteDraft fires when the draft portion finishes. Carries
  # the full card pool and whether this was a bot or human draft.
  def translate(
        %EventRecord{event_type: "DraftCompleteDraft"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         false <- Map.has_key?(payload, "request") do
      {[
         %DraftCompleted{
           mtga_draft_id: payload["EventName"] || payload["InternalEventName"],
           event_name: payload["EventName"] || payload["InternalEventName"],
           is_bot_draft: payload["IsBotDraft"],
           card_pool_arena_ids: payload["CardPool"],
           occurred_at: occurred_at
         }
       ], []}
    else
      true -> {[], []}
      _ -> {[], translation_warning(record, "failed to decode DraftCompleteDraft payload")}
    end
  end

  # AuthenticateResponse carries the player's Wizards client_id and
  # screen name. Emits a SessionStarted for auto-detecting self_user_id.
  def translate(
        %EventRecord{event_type: "AuthenticateResponse"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         %{"authenticateResponse" => auth} <- payload do
      {[
         %SessionStarted{
           client_id: auth["clientId"],
           screen_name: auth["screenName"],
           session_id: auth["sessionId"],
           occurred_at: occurred_at
         }
       ], []}
    else
      _ ->
        {[],
         [
           %TranslationWarning{
             category: :payload_extraction_failed,
             raw_event_id: record.id,
             event_type: record.event_type,
             detail: "failed to decode/extract authenticateResponse"
           }
         ]}
    end
  end

  # FrontDoorConnection.Close signals the player disconnected.
  # The payload is typically empty or minimal — we only need the timestamp.
  def translate(
        %EventRecord{event_type: "FrontDoorConnection.Close"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at
    {[%SessionDisconnected{occurred_at: occurred_at}], []}
  end

  # Rank response events carry the full rank state. Both
  # RankGetSeasonAndRankDetails and RankGetCombinedRankInfo share the
  # same payload shape. REQUEST events have a "request" key and are
  # skipped.
  @rank_event_types ~w(RankGetSeasonAndRankDetails RankGetCombinedRankInfo)
  def translate(
        %EventRecord{event_type: event_type} = record,
        _self_user_id,
        _match_context
      )
      when event_type in @rank_event_types do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         false <- Map.has_key?(payload, "request") do
      {[
         %RankSnapshot{
           constructed_class: payload["constructedClass"],
           constructed_level: payload["constructedLevel"],
           constructed_step: payload["constructedStep"],
           constructed_matches_won: payload["constructedMatchesWon"],
           constructed_matches_lost: payload["constructedMatchesLost"],
           constructed_percentile: payload["constructedMatchmakingPercentile"],
           constructed_leaderboard_placement: payload["constructedLeaderboardPlacement"],
           limited_class: payload["limitedClass"],
           limited_level: payload["limitedLevel"],
           limited_step: payload["limitedStep"],
           limited_matches_won: payload["limitedMatchesWon"],
           limited_matches_lost: payload["limitedMatchesLost"],
           limited_percentile: payload["limitedMatchmakingPercentile"],
           limited_leaderboard_placement: payload["limitedLeaderboardPlacement"],
           season_ordinal: payload["constructedSeasonOrdinal"],
           occurred_at: occurred_at
         }
       ], []}
    else
      # `true` from Map.has_key? means this is a REQUEST event, not a response.
      # Legitimately nothing to do — no warning.
      true ->
        {[], []}

      _ ->
        {[],
         [
           %TranslationWarning{
             category: :payload_extraction_failed,
             raw_event_id: record.id,
             event_type: record.event_type,
             detail: "failed to decode rank response payload"
           }
         ]}
    end
  end

  # ── Event participation + economy ────────────────────────────────────
  #
  # EventJoin and EventClaimPrize carry both course info and inventory
  # changes. Each produces its primary event + InventoryChanged events
  # from InventoryInfo.Changes[].

  # EventJoin response carries Course (enrollment) + InventoryInfo (entry fee).
  # Request format has {"id", "request"} — skip it.
  def translate(
        %EventRecord{event_type: "EventJoin"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         %{"Course" => course, "InventoryInfo" => inventory_info} <- payload do
      event_name = course["InternalEventName"]

      joined =
        %EventJoined{
          event_name: event_name,
          course_id: course["CourseId"],
          entry_currency_type: detect_entry_currency(inventory_info),
          entry_fee: detect_entry_fee(inventory_info),
          occurred_at: occurred_at
        }

      inventory_events = build_inventory_changed(inventory_info, occurred_at)

      {[joined | inventory_events], []}
    else
      %{"request" => _} -> {[], []}
      _ -> {[], translation_warning(record, "failed to decode EventJoin response")}
    end
  end

  # EventClaimPrize response carries Course (final record) + InventoryInfo (rewards).
  # Emits EventRewardClaimed + InventoryUpdated always. Also emits DraftCompleted when
  # Course.CurrentModule is "Complete" and CardPool is present — this is the primary
  # draft-completion signal for Quick Draft (bot draft). DraftCompleteDraft is not
  # emitted by MTGA for bot drafts. Request format has {"id", "request"} — skip it.
  def translate(
        %EventRecord{event_type: "EventClaimPrize"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         %{"Course" => course, "InventoryInfo" => inventory} <- payload do
      changes = (inventory["Changes"] || []) |> List.first() || %{}

      reward_event = %EventRewardClaimed{
        event_name: course["InternalEventName"],
        final_wins: course["CurrentWins"],
        final_losses: course["CurrentLosses"],
        gems_awarded: changes["InventoryGems"],
        gold_awarded: changes["InventoryGold"],
        boosters_awarded: changes["Boosters"],
        card_pool: course["CardPool"],
        occurred_at: occurred_at
      }

      inventory_event = %InventoryUpdated{
        gold: inventory["Gold"],
        gems: inventory["Gems"],
        wildcards_common: inventory["WildCardCommons"],
        wildcards_uncommon: inventory["WildCardUnCommons"],
        wildcards_rare: inventory["WildCardRares"],
        wildcards_mythic: inventory["WildCardMythics"],
        vault_progress: safe_divide(inventory["TotalVaultProgress"], 10),
        draft_tokens: inventory["DraftTokens"],
        sealed_tokens: inventory["SealedTokens"],
        occurred_at: occurred_at
      }

      draft_events =
        case {course["CurrentModule"], course["CardPool"], course["InternalEventName"]} do
          {"Complete", card_pool, draft_id} when is_list(card_pool) and is_binary(draft_id) ->
            [
              %DraftCompleted{
                mtga_draft_id: draft_id,
                event_name: draft_id,
                is_bot_draft:
                  String.contains?(draft_id, "BotDraft") or
                    String.starts_with?(draft_id, "QuickDraft"),
                card_pool_arena_ids: card_pool,
                occurred_at: occurred_at
              }
            ]

          _ ->
            []
        end

      {[reward_event, inventory_event] ++ draft_events, []}
    else
      %{"request" => _} -> {[], []}
      _ -> {[], translation_warning(record, "failed to decode EventClaimPrize response")}
    end
  end

  # EventEnterPairing request carries EventName — marks the moment the
  # player clicked "Play" and entered the match queue.
  def translate(
        %EventRecord{event_type: "EventEnterPairing"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         {:ok, request} <- decode_request_field(payload) do
      {[
         %PairingEntered{
           event_name: request["EventName"],
           occurred_at: occurred_at
         }
       ], []}
    else
      _ -> {[], []}
    end
  end

  # ── Deck management ──────────────────────────────────────────────────

  # EventSetDeckV2/V3 request carries the full deck list for an event.
  # V3 is a protocol upgrade of V2; the request payload structure is identical.
  # Responses carry a course confirmation payload and are skipped (decode_request_field fails).
  def translate(
        %EventRecord{event_type: type} = record,
        _self_user_id,
        _match_context
      )
      when type in ["EventSetDeckV2", "EventSetDeckV3"] do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         {:ok, request} <- decode_request_field(payload) do
      summary = request["Summary"] || %{}
      deck = request["Deck"] || %{}

      main_deck = build_card_list(deck["MainDeck"] || [])
      sideboard = build_card_list(deck["Sideboard"] || [])

      {[
         %DeckSelected{
           event_name: request["EventName"],
           deck_id: summary["DeckId"],
           deck_name: summary["Name"],
           main_deck: main_deck,
           sideboard: sideboard,
           occurred_at: occurred_at
         }
       ], []}
    else
      _ -> {[], []}
    end
  end

  # DeckUpsertDeckV2/V3 request carries a deck create/edit/clone operation
  # with the full deck list and an ActionType discriminator.
  # V3 is a protocol upgrade of V2; the request payload structure is identical.
  # Responses carry a slim deck summary (no card list) and are skipped (decode_request_field fails).
  def translate(
        %EventRecord{event_type: type} = record,
        _self_user_id,
        _match_context
      )
      when type in ["DeckUpsertDeckV2", "DeckUpsertDeckV3"] do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         {:ok, request} <- decode_request_field(payload) do
      summary = request["Summary"] || %{}
      deck = request["Deck"] || %{}

      format =
        summary["Attributes"]
        |> extract_attribute("Format")
        |> normalize_deck_format()

      main_deck = build_card_list(deck["MainDeck"] || [])
      sideboard = build_card_list(deck["Sideboard"] || [])

      {[
         %DeckUpdated{
           deck_id: summary["DeckId"],
           deck_name: summary["Name"],
           format: format,
           action_type: request["ActionType"],
           main_deck: main_deck,
           sideboard: sideboard,
           occurred_at: occurred_at
         }
       ], []}
    else
      _ -> {[], []}
    end
  end

  # DeckGetDeckSummariesV2 response carries the full deck collection.
  # Request format has {"id", "request"} — skip it.
  def translate(
        %EventRecord{event_type: "DeckGetDeckSummariesV2"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         %{"Summaries" => summaries} when is_list(summaries) <- payload do
      decks =
        Enum.map(summaries, fn summary ->
          format =
            summary["Attributes"]
            |> extract_attribute("Format")
            |> normalize_deck_format()

          %{
            deck_id: summary["DeckId"],
            name: summary["Name"],
            format: format
          }
        end)

      {[%DeckInventory{decks: decks, occurred_at: occurred_at}], []}
    else
      _ -> {[], []}
    end
  end

  # ── Progress tracking ──────────────────────────────────────────────────

  # QuestGetQuests response carries the current quest assignments.
  # Request format has {"id", "request"} — skip it.
  def translate(
        %EventRecord{event_type: "QuestGetQuests"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         %{"quests" => quests} when is_list(quests) <- payload do
      quest_data =
        Enum.map(quests, fn quest ->
          chest = quest["chestDescription"] || %{}
          loc_params = chest["locParams"] || %{}

          %{
            quest_id: quest["questId"],
            goal: quest["goal"],
            progress: quest["endingProgress"] || 0,
            quest_track: quest["questTrack"],
            reward_gold: loc_params["number1"],
            reward_xp: loc_params["number2"]
          }
        end)

      {[%QuestStatus{quests: quest_data, occurred_at: occurred_at}], []}
    else
      _ -> {[], []}
    end
  end

  # PeriodicRewardsGetStatus response carries daily/weekly win progress.
  # Request format has {"id", "request"} — skip it.
  def translate(
        %EventRecord{event_type: "PeriodicRewardsGetStatus"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         daily when is_integer(daily) <- payload["_dailyRewardSequenceId"] do
      {[
         %DailyWinsStatus{
           daily_position: daily,
           daily_reset_at: parse_timestamp(payload["_dailyRewardResetTimestamp"]),
           weekly_position: payload["_weeklyRewardSequenceId"],
           weekly_reset_at: parse_timestamp(payload["_weeklyRewardResetTimestamp"]),
           occurred_at: occurred_at
         }
       ], []}
    else
      _ -> {[], []}
    end
  end

  # EventGetCoursesV2 response carries all active event enrollments.
  # Each course with a non-empty InternalEventName becomes a separate
  # EventCourseUpdated event. Request format has {"id", "request"} — skip it.
  def translate(
        %EventRecord{event_type: "EventGetCoursesV2"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         courses when is_list(courses) <- payload["Courses"] do
      events =
        courses
        |> Enum.filter(fn course ->
          name = course["InternalEventName"]
          name != nil and name != ""
        end)
        |> Enum.map(fn course ->
          %EventCourseUpdated{
            event_name: course["InternalEventName"],
            current_wins: course["CurrentWins"],
            current_losses: course["CurrentLosses"],
            current_module: course["CurrentModule"],
            card_pool: course["CardPool"],
            occurred_at: occurred_at
          }
        end)

      {events, []}
    else
      _ -> {[], []}
    end
  end

  # StartHook fires on every MTGA client login and carries an InventoryInfo
  # snapshot with gold, gems, wildcards, and vault progress.
  def translate(%EventRecord{event_type: "StartHook"} = record, _self_user_id, _match_context) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         %{"InventoryInfo" => inventory} when is_map(inventory) <- payload do
      event = %InventoryUpdated{
        gold: inventory["Gold"],
        gems: inventory["Gems"],
        wildcards_common: inventory["WildCardCommons"],
        wildcards_uncommon: inventory["WildCardUnCommons"],
        wildcards_rare: inventory["WildCardRares"],
        wildcards_mythic: inventory["WildCardMythics"],
        vault_progress: safe_divide(inventory["TotalVaultProgress"], 10),
        draft_tokens: inventory["DraftTokens"],
        sealed_tokens: inventory["SealedTokens"],
        occurred_at: occurred_at
      }

      {[event], []}
    else
      _ -> {[], []}
    end
  end

  # ── GraphGetGraphState → MasteryProgress ──────────────────────────

  def translate(
        %EventRecord{event_type: "GraphGetGraphState"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         %{"NodeStates" => node_states} when is_map(node_states) <- payload do
      total = map_size(node_states)

      completed =
        Enum.count(node_states, fn {_id, state} ->
          is_map(state) and state["Status"] == "Completed"
        end)

      milestone_states =
        case payload do
          %{"MilestoneStates" => ms} when is_map(ms) -> ms
          _ -> nil
        end

      event = %MasteryProgress{
        node_states: node_states,
        milestone_states: milestone_states,
        total_nodes: total,
        completed_nodes: completed,
        occurred_at: occurred_at
      }

      {[event], []}
    else
      # Request event or missing NodeStates — skip
      _ -> {[], []}
    end
  end

  # ── Economy — standalone snapshots ───────────────────────────────

  # PlayerInventory.GetPlayerCardsV3 response carries the full card
  # collection as a map of string arena_id → count. Request events
  # have a "request" key and are skipped.
  def translate(
        %EventRecord{event_type: "PlayerInventory.GetPlayerCardsV3"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         false <- Map.has_key?(payload, "request") do
      # Payload is a flat map of "arena_id_string" => count
      card_counts =
        payload
        |> Enum.reduce(%{}, fn
          {key, count}, acc when is_integer(count) ->
            case Integer.parse(key) do
              {arena_id, ""} -> Map.put(acc, arena_id, count)
              _ -> acc
            end

          _, acc ->
            acc
        end)

      {[%CollectionUpdated{card_counts: card_counts, occurred_at: occurred_at}], []}
    else
      true ->
        {[], []}

      _ ->
        {[],
         translation_warning(record, "failed to decode PlayerInventory.GetPlayerCardsV3 response")}
    end
  end

  # DTO_InventoryInfo is a standalone push event carrying the full
  # economy state. Unlike StartHook/EventClaimPrize which produce
  # InventoryUpdated, this fires on miscellaneous inventory changes.
  def translate(
        %EventRecord{event_type: "DTO_InventoryInfo"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         false <- Map.has_key?(payload, "request") do
      boosters =
        case payload["Boosters"] do
          boosters when is_list(boosters) ->
            Enum.map(boosters, fn booster ->
              %{set_code: booster["CollationId"] || booster["SetCode"], count: booster["Count"]}
            end)

          _ ->
            nil
        end

      {[
         %InventorySnapshot{
           gold: payload["Gold"],
           gems: payload["Gems"],
           vault_progress: safe_divide(payload["TotalVaultProgress"], 10),
           wildcards_common: payload["WildCardCommons"],
           wildcards_uncommon: payload["WildCardUnCommons"],
           wildcards_rare: payload["WildCardRares"],
           wildcards_mythic: payload["WildCardMythics"],
           draft_tokens: payload["DraftTokens"],
           sealed_tokens: payload["SealedTokens"],
           boosters: boosters,
           occurred_at: occurred_at
         }
       ], []}
    else
      true -> {[], []}
      _ -> {[], translation_warning(record, "failed to decode DTO_InventoryInfo response")}
    end
  end

  # Fall-through: raw event types we don't translate (yet or ever)
  # produce no domain events. The raw event is still preserved in
  # mtga_logs_events for future reprocessing via retranslate_from_raw!/0.
  def translate(%EventRecord{}, _self_user_id, _match_context), do: {[], []}

  # ── Event participation + economy helpers ───────────────────────────

  defp detect_entry_currency(inventory_info) do
    case get_in(inventory_info, ["Changes", Access.at(0)]) do
      %{"InventoryGold" => gold} when is_integer(gold) and gold < 0 -> "Gold"
      %{"InventoryGems" => gems} when is_integer(gems) and gems < 0 -> "Gems"
      _ -> nil
    end
  end

  defp detect_entry_fee(inventory_info) do
    case get_in(inventory_info, ["Changes", Access.at(0)]) do
      %{"InventoryGold" => gold} when is_integer(gold) and gold < 0 -> abs(gold)
      %{"InventoryGems" => gems} when is_integer(gems) and gems < 0 -> abs(gems)
      _ -> nil
    end
  end

  defp build_inventory_changed(inventory_info, occurred_at) do
    changes = inventory_info["Changes"] || []
    gold_balance = inventory_info["Gold"]
    gems_balance = inventory_info["Gems"]

    Enum.map(changes, fn change ->
      boosters =
        (change["Boosters"] || [])
        |> Enum.map(fn booster ->
          %{set_code: booster["SetCode"], count: booster["Count"]}
        end)
        |> case do
          [] -> nil
          list -> list
        end

      %InventoryChanged{
        source: change["Source"],
        source_id: change["SourceId"],
        gold_delta: change["InventoryGold"],
        gems_delta: change["InventoryGems"],
        boosters: boosters,
        gold_balance: gold_balance,
        gems_balance: gems_balance,
        occurred_at: occurred_at
      }
    end)
  end

  defp translation_warning(record, detail) do
    [
      %TranslationWarning{
        category: :payload_extraction_failed,
        raw_event_id: record.id,
        event_type: record.event_type,
        detail: detail
      }
    ]
  end

  # ── Deck management helpers ──────────────────────────────────────────

  # Converts [{cardId, quantity}] maps to [%{arena_id, count}] structs.
  defp build_card_list(cards) when is_list(cards) do
    Enum.map(cards, fn card ->
      %{arena_id: card["cardId"], count: card["quantity"]}
    end)
  end

  defp extract_attribute(nil, _name), do: nil

  defp extract_attribute(attributes, name) when is_list(attributes) do
    Enum.find_value(attributes, fn
      %{"name" => ^name, "value" => value} -> value
      _ -> nil
    end)
  end

  # MTGA's DeckUpsertDeckV2 sometimes sets the "Format" attribute to an
  # event-type string (e.g. "DirectGame", "DirectGameLimited") instead of
  # the actual constructed format ("Standard", "Historic", etc.). This
  # happens when a deck is submitted for a direct challenge — MTGA
  # overwrites the format with the queue type. Filter these out so the
  # deck's format field reflects the true constructed format.
  @valid_deck_formats ~w(Standard Historic Alchemy Explorer Timeless Brawl StandardBrawl Pauper)

  defp normalize_deck_format(nil), do: nil

  defp normalize_deck_format(format) when format in @valid_deck_formats, do: format

  defp normalize_deck_format(_unrecognized), do: nil

  # ── Timestamp parsing ──────────────────────────────────────────────────

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  # ── Draft event helpers ──────────────────────────────────────────────

  defp translate_draft_pick_request(%{"PickInfo" => pick_info} = request, record) do
    occurred_at = record.mtga_timestamp || record.inserted_at
    event_name = pick_info["EventName"] || request["EventName"]
    card_ids = pick_info["CardIds"] || []
    picked_arena_id = card_ids |> List.first() |> parse_arena_id()

    if picked_arena_id do
      {[
         %DraftPickMade{
           mtga_draft_id: event_name,
           pack_number: pick_info["PackNumber"] + 1,
           pick_number: pick_info["PickNumber"] + 1,
           picked_arena_id: picked_arena_id,
           pack_arena_ids: [],
           auto_pick: pick_info["AutoPick"],
           time_remaining: pick_info["TimeRemainingOnPick"],
           occurred_at: occurred_at
         }
       ], []}
    else
      {[], []}
    end
  end

  defp translate_draft_pick_request(_request, record), do: draft_pick_warning(record)

  defp draft_pick_warning(record) do
    {[],
     [
       %TranslationWarning{
         category: :payload_extraction_failed,
         raw_event_id: record.id,
         event_type: record.event_type,
         detail: "failed to decode/extract draft pick request"
       }
     ]}
  end

  # Decodes a BotDraftDraftStatus or BotDraftDraftPick response Payload and
  # emits HumanDraftPackOffered for the pack being offered at the next pick.
  # PackNumber and PickNumber in the response are 0-indexed; we convert to 1-indexed
  # to match DraftPickMade. DraftPack must be non-empty — empty means no next pick.
  defp translate_bot_pack_response(record) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, outer} <- Jason.decode(record.raw_json),
         payload_str when is_binary(payload_str) <- outer["Payload"],
         {:ok, inner} <- Jason.decode(payload_str),
         [_ | _] = pack_strs <- inner["DraftPack"],
         draft_id when is_binary(draft_id) <- inner["EventName"],
         pick_number when is_integer(pick_number) <- inner["PickNumber"],
         pack_number when is_integer(pack_number) <- inner["PackNumber"] do
      arena_ids = Enum.map(pack_strs, &parse_arena_id/1) |> Enum.reject(&is_nil/1)

      {[
         %HumanDraftPackOffered{
           mtga_draft_id: draft_id,
           pack_number: pack_number + 1,
           pick_number: pick_number + 1,
           pack_arena_ids: arena_ids,
           occurred_at: occurred_at
         }
       ], []}
    else
      _ -> {[], []}
    end
  end

  # BotDraftDraftPick and BotDraftDraftStatus carry a double-encoded
  # JSON string in the "request" field. Decode it to a map.
  defp decode_request_field(%{"request" => request}) when is_binary(request) do
    Jason.decode(request)
  end

  defp decode_request_field(_), do: :error

  # CardIds in draft picks come as strings ("93959"). Parse to integer.
  defp parse_arena_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_arena_id(id) when is_integer(id), do: id
  defp parse_arena_id(_), do: nil

  defp safe_divide(nil, _divisor), do: nil
  defp safe_divide(value, divisor) when is_number(value), do: value / divisor
end
