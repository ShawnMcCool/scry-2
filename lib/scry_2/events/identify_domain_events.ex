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
  """

  alias Scry2.Events.Deck.{DeckInventory, DeckSelected, DeckSubmitted, DeckUpdated}

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

  alias Scry2.Events.Gameplay.{
    GameConceded,
    MulliganDecided,
    MulliganOffered,
    StartingPlayerChosen,
    CardDrawn,
    CardExiled,
    CombatDamageDealt,
    CounterAdded,
    LandPlayed,
    LifeTotalChanged,
    PermanentDestroyed,
    SpellCast,
    SpellResolved,
    TokenCreated,
    ZoneChanged
  }

  alias Scry2.Events.Match.{DieRolled, GameCompleted, MatchCompleted, MatchCreated}
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
                         "DeckGetDeckSummariesV2",
                         "DeckUpsertDeckV2",
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
                         "EventGetActiveMatches"
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
          optional(:last_hand_game_objects) => map() | {integer(), list()}
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
        _match_context
      ) do
    with {:ok, payload} <- Jason.decode(record.raw_json),
         {:ok, info} <- extract_game_room_info(payload) do
      case info["stateType"] do
        "MatchGameRoomStateType_Playing" ->
          {maybe_build_match_created(info, record, self_user_id), []}

        "MatchGameRoomStateType_MatchCompleted" ->
          {maybe_build_match_completed(info, record, self_user_id), []}

        _ ->
          {[], []}
      end
    else
      _ ->
        {[],
         [
           %TranslationWarning{
             category: :payload_extraction_failed,
             raw_event_id: record.id,
             event_type: record.event_type,
             detail: "failed to decode/extract gameRoomInfo"
           }
         ]}
    end
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
      match_id = extract_match_id_from_gre(messages)
      context_match_id = match_id || match_context[:current_match_id]

      events =
        [
          maybe_build_deck_submitted(messages, context_match_id, occurred_at),
          maybe_build_die_roll_completed(messages, context_match_id, occurred_at),
          maybe_build_game_completed(messages, context_match_id, occurred_at),
          build_mulligan_offered(messages, context_match_id, occurred_at, match_context),
          build_turn_actions(messages, context_match_id, occurred_at, match_context)
        ]
        |> List.flatten()
        |> Enum.reject(&is_nil/1)

      {events, []}
    else
      _ ->
        {[],
         [
           %TranslationWarning{
             category: :payload_extraction_failed,
             raw_event_id: record.id,
             event_type: record.event_type,
             detail: "failed to decode/extract greToClientMessages"
           }
         ]}
    end
  end

  # ClientToGremessage carries the player's in-game actions. Most are
  # high-volume UI responses (PerformActionResp, SelectTargetsResp) that
  # we skip. We extract only high-signal decisions: concede, mulligan
  # response, and play/draw choice.
  def translate(
        %EventRecord{event_type: "ClientToGremessage"} = record,
        _self_user_id,
        match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at
    match_id = match_context[:current_match_id]

    with {:ok, payload} <- Jason.decode(record.raw_json),
         %{"type" => msg_type} = gre_payload <- payload["payload"] || payload do
      event =
        case msg_type do
          "ClientMessageType_ConcedeReq" ->
            scope = get_in(gre_payload, ["concedeReq", "scope"])

            %GameConceded{
              mtga_match_id: match_id,
              scope: scope,
              occurred_at: occurred_at
            }

          "ClientMessageType_MulliganResp" ->
            raw_decision = get_in(gre_payload, ["mulliganResp", "decision"])

            decision =
              case raw_decision do
                "MulliganOption_AcceptHand" -> "keep"
                "MulliganOption_Mulligan" -> "mulligan"
                other -> other
              end

            %MulliganDecided{
              mtga_match_id: match_id,
              decision: decision,
              occurred_at: occurred_at
            }

          "ClientMessageType_ChooseStartingPlayerResp" ->
            seat = get_in(gre_payload, ["chooseStartingPlayerResp", "systemSeatId"])

            %StartingPlayerChosen{
              mtga_match_id: match_id,
              chose_play: seat == 1,
              occurred_at: occurred_at
            }

          _ ->
            nil
        end

      if event, do: {[event], []}, else: {[], []}
    else
      _ -> {[], []}
    end
  end

  # BotDraftDraftStatus has two wire formats (request ==> and response <==).
  # The request carries a double-encoded JSON `request` string with the
  # EventName (format identifier like "QuickDraft_FDN_20260323").
  # The response carries a "Payload" with draft state — we skip it silently.
  def translate(
        %EventRecord{event_type: "BotDraftDraftStatus"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         {:ok, request} <- decode_request_field(payload) do
      event_name = request["EventName"]
      set_code = extract_set_code(event_name)

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
            {[], []}

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
  #   Response (<==) — {"CurrentModule", "Payload": "{\"DraftPack\": ...}"} — server ack with next pack
  # We only need the request; the response is a server confirmation that
  # carries the next pack state but requires stateful correlation to be useful.
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
          {:ok, %{"Payload" => _}} -> {[], []}
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
  # Emits EventRewardClaimed (rich reward detail) and InventoryUpdated (economy snapshot).
  # Request format has {"id", "request"} — skip it.
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

      {[reward_event, inventory_event], []}
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

  # EventSetDeckV2 request carries the full deck list for an event.
  def translate(
        %EventRecord{event_type: "EventSetDeckV2"} = record,
        _self_user_id,
        _match_context
      ) do
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

  # DeckUpsertDeckV2 request carries a deck create/edit/clone operation
  # with the full deck list and an ActionType discriminator.
  def translate(
        %EventRecord{event_type: "DeckUpsertDeckV2"} = record,
        _self_user_id,
        _match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         {:ok, request} <- decode_request_field(payload) do
      summary = request["Summary"] || %{}
      deck = request["Deck"] || %{}
      format = extract_attribute(summary["Attributes"], "Format")

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
          format = extract_attribute(summary["Attributes"], "Format")

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

    with {:ok, payload} <- JSON.decode(record.raw_json),
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

  # ── MatchCreated construction ───────────────────────────────────────

  defp maybe_build_match_created(info, record, self_user_id) do
    config = info["gameRoomConfig"] || %{}
    match_id = config["matchId"]
    reserved = config["reservedPlayers"] || []

    if is_binary(match_id) and match_id != "" do
      opponent = find_opponent(reserved, self_user_id)
      self_entry = find_self_entry(reserved, self_user_id)
      event_name = find_event_name(reserved, self_user_id)
      opponent_rank = opponent["playerRankInfo"] || %{}

      [
        %MatchCreated{
          mtga_match_id: match_id,
          event_name: event_name,
          opponent_screen_name: opponent["playerName"],
          opponent_user_id: opponent["userId"],
          platform: self_entry && self_entry["platformId"],
          opponent_platform: opponent["platformId"],
          opponent_rank_class: opponent_rank["rankClass"],
          opponent_rank_tier: opponent_rank["rankTier"],
          opponent_leaderboard_percentile: opponent_rank["leaderboardPercentile"],
          opponent_leaderboard_placement: opponent_rank["leaderboardPlacement"],
          occurred_at: record.mtga_timestamp || record.inserted_at
        }
      ]
    else
      []
    end
  end

  # ── MatchCompleted construction ─────────────────────────────────────

  defp maybe_build_match_completed(info, record, self_user_id) do
    config = info["gameRoomConfig"] || %{}
    match_id = config["matchId"]
    reserved = config["reservedPlayers"] || []
    final_result = info["finalMatchResult"] || %{}
    result_list = final_result["resultList"] || []

    with true <- is_binary(match_id) and match_id != "",
         self_team when is_integer(self_team) <- find_self_team_id(reserved, self_user_id),
         match_scope when is_map(match_scope) <- find_match_scope_result(result_list) do
      num_games = count_game_scope_results(result_list)
      winning_team = match_scope["winningTeamId"]
      game_results = build_game_results(result_list)

      [
        %MatchCompleted{
          mtga_match_id: match_id,
          occurred_at: record.mtga_timestamp || record.inserted_at,
          won: winning_team == self_team,
          num_games: num_games,
          reason: final_result["matchCompletedReason"],
          game_results: game_results
        }
      ]
    else
      _ -> []
    end
  end

  # ── Helpers for self/opponent identification ────────────────────────

  defp extract_game_room_info(%{"matchGameRoomStateChangedEvent" => %{"gameRoomInfo" => info}}),
    do: {:ok, info}

  defp extract_game_room_info(_), do: :error

  # Find the opponent entry in reservedPlayers[]. When self_user_id is
  # known, filter out that user. When nil, assume self is seat 1 and
  # return whoever isn't seat 1.
  defp find_opponent(reserved, self_user_id) when is_binary(self_user_id) do
    Enum.find(reserved, %{}, fn player ->
      player["userId"] && player["userId"] != self_user_id
    end)
  end

  defp find_opponent(reserved, nil) do
    Enum.find(reserved, %{}, fn player -> player["systemSeatId"] != 1 end)
  end

  # The user's own reservedPlayers[] entry carries the eventId for the
  # format they joined (`Traditional_Ladder`, `PremierDraft_LCI_...`).
  defp find_event_name(reserved, self_user_id) do
    self_entry = find_self_entry(reserved, self_user_id)

    case self_entry do
      %{"eventId" => event_id} when is_binary(event_id) -> event_id
      _ -> nil
    end
  end

  defp find_self_team_id(reserved, self_user_id) do
    case find_self_entry(reserved, self_user_id) do
      %{"teamId" => team_id} when is_integer(team_id) -> team_id
      _ -> nil
    end
  end

  defp find_self_entry(reserved, self_user_id) when is_binary(self_user_id) do
    Enum.find(reserved, fn player -> player["userId"] == self_user_id end)
  end

  defp find_self_entry(reserved, nil) do
    Enum.find(reserved, fn player -> player["systemSeatId"] == 1 end)
  end

  # ── finalMatchResult.resultList parsing ─────────────────────────────

  defp find_match_scope_result(result_list) do
    Enum.find(result_list, fn row -> row["scope"] == "MatchScope_Match" end)
  end

  defp count_game_scope_results(result_list) do
    Enum.count(result_list, fn row -> row["scope"] == "MatchScope_Game" end)
  end

  defp build_game_results(result_list) do
    result_list
    |> Enum.filter(fn row -> row["scope"] == "MatchScope_Game" end)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, index} ->
      %{game_number: index, winning_team_id: row["winningTeamId"], reason: row["reason"]}
    end)
  end

  # ── GRE message extraction ────────────────────────────────────────────
  #
  # GreToClientEvent.greToClientMessages[] is a flat array of typed
  # messages. Each message has a "type" discriminator. These helpers
  # find specific message types and extract domain events from them.

  defp extract_match_id_from_gre(messages) do
    Enum.find_value(messages, fn msg ->
      if game_state_message?(msg) do
        get_in(extract_game_state(msg), ["gameInfo", "matchID"])
      end
    end)
  end

  # ConnectResp carries the deck list as flat arrays of arena_ids (one
  # entry per copy). Aggregate into [%{arena_id, count}] shape.
  defp maybe_build_deck_submitted(messages, match_id, occurred_at) do
    case find_gre_message(messages, "GREMessageType_ConnectResp") do
      %{"connectResp" => connect_resp} = message ->
        deck_message = connect_resp["deckMessage"] || %{}
        seat_id = message["systemSeatIds"] |> List.first()

        main_deck = aggregate_card_list(deck_message["deckCards"] || [])
        sideboard = aggregate_card_list(deck_message["sideboardCards"] || [])

        deck_id = if match_id, do: "#{match_id}:seat#{seat_id}", else: "pending:seat#{seat_id}"

        %DeckSubmitted{
          mtga_match_id: match_id,
          mtga_deck_id: deck_id,
          main_deck: main_deck,
          sideboard: sideboard,
          occurred_at: occurred_at
        }

      _ ->
        nil
    end
  end

  # GameStateMessage with matchState "MatchState_GameComplete" carries
  # per-game results including winner, game number, and player stats.
  # Self is assumed to be systemSeatNumber 1 (same as match events).
  defp maybe_build_game_completed(messages, match_id, occurred_at)
       when is_binary(match_id) do
    Enum.find_value(messages, fn msg ->
      with true <- game_state_message?(msg),
           gsm when is_map(gsm) <- extract_game_state(msg),
           game_info when is_map(game_info) <- gsm["gameInfo"],
           "MatchState_GameComplete" <- game_info["matchState"] do
        results = game_info["results"] || []
        game_result = Enum.find(results, &(&1["scope"] == "MatchScope_Game"))
        players = gsm["players"] || []
        self_player = Enum.find(players, &(&1["systemSeatNumber"] == 1))
        opponent_player = Enum.find(players, &(&1["systemSeatNumber"] != 1))
        self_team = self_player && self_player["teamId"]

        %GameCompleted{
          mtga_match_id: match_id,
          game_number: game_info["gameNumber"],
          on_play: nil,
          won: game_result && self_team && game_result["winningTeamId"] == self_team,
          num_mulligans: self_player && self_player["mulliganCount"],
          opponent_num_mulligans: opponent_player && opponent_player["mulliganCount"],
          num_turns: self_player && self_player["turnNumber"],
          self_life_total: self_player && self_player["lifeTotal"],
          opponent_life_total: opponent_player && opponent_player["lifeTotal"],
          win_reason: game_result && game_result["reason"],
          super_format: game_info["superFormat"],
          occurred_at: occurred_at
        }
      else
        _ -> nil
      end
    end)
  end

  defp maybe_build_game_completed(_messages, _match_id, _occurred_at), do: nil

  # DieRollResultsResp carries both players' roll values. The higher
  # roll wins and chooses to play first (virtually always chooses play).
  defp maybe_build_die_roll_completed(messages, match_id, occurred_at)
       when is_binary(match_id) do
    case find_gre_message(messages, "GREMessageType_DieRollResultsResp") do
      %{"dieRollResultsResp" => %{"playerDieRolls" => rolls}} ->
        self_roll_entry = Enum.find(rolls, &(&1["systemSeatId"] == 1))
        opponent_roll_entry = Enum.find(rolls, &(&1["systemSeatId"] != 1))

        if self_roll_entry && opponent_roll_entry do
          self_roll = self_roll_entry["rollValue"]
          opponent_roll = opponent_roll_entry["rollValue"]

          %DieRolled{
            mtga_match_id: match_id,
            self_roll: self_roll,
            opponent_roll: opponent_roll,
            self_goes_first: self_roll > opponent_roll,
            occurred_at: occurred_at
          }
        end

      _ ->
        nil
    end
  end

  defp maybe_build_die_roll_completed(_messages, _match_id, _occurred_at), do: nil

  # MulliganReq messages offer a mulligan decision to a specific seat.
  # Returns a list (not a single value) since a batch can contain
  # multiple mulligan offers.
  #
  # Hand card extraction: the accompanying GameStateMessage contains
  # zones (ZoneType_Hand) with objectInstanceIds and gameObjects with
  # grpId (arena_id). We map instance IDs → arena_ids for the player's
  # seat to capture the actual opening hand.
  defp build_mulligan_offered(messages, match_id, occurred_at, match_context) do
    game_state = extract_game_state_for_mulligans(messages)
    cached_objects = match_context[:last_hand_game_objects] || %{}

    messages
    |> Enum.filter(&(&1["type"] == "GREMessageType_MulliganReq"))
    |> Enum.map(fn message ->
      seat_id = message["systemSeatIds"] |> List.first()

      hand_size =
        get_in(message, ["prompt", "parameters"])
        |> List.wrap()
        |> Enum.find_value(fn
          %{"parameterName" => "NumberOfCards", "numberValue" => n} -> n
          _ -> nil
        end)

      hand_arena_ids = extract_hand_arena_ids(game_state, seat_id, cached_objects)

      %MulliganOffered{
        mtga_match_id: match_id,
        seat_id: seat_id,
        hand_size: hand_size || 7,
        hand_arena_ids: hand_arena_ids,
        occurred_at: occurred_at
      }
    end)
  end

  defp extract_game_state_for_mulligans(messages) do
    messages
    |> Enum.find_value(fn msg ->
      if game_state_message?(msg), do: extract_game_state(msg)
    end)
  end

  @doc """
  Extracts the player's hand as a resolved `{seat_id, [arena_id, ...]}`
  tuple from a GreToClientEvent's GRE messages. Called by IngestRawEvents
  to cache the most recently seen hand across sequential events.

  Only returns a result when the GameStateMessage contains both a
  ZoneType_Hand zone and gameObjects to resolve instance IDs. Returns
  nil otherwise.
  """
  def extract_resolved_hand(messages) when is_list(messages) do
    gsm =
      Enum.find_value(messages, fn msg ->
        if game_state_message?(msg), do: extract_game_state(msg)
      end)

    with %{"zones" => zones, "gameObjects" => objects}
         when is_list(zones) and is_list(objects) and objects != [] <- gsm do
      instance_to_grp = Map.new(objects, fn obj -> {obj["instanceId"], obj["grpId"]} end)

      Enum.find_value(zones, fn
        %{"type" => "ZoneType_Hand", "ownerSeatId" => seat_id, "objectInstanceIds" => ids}
        when is_list(ids) ->
          resolved = Enum.map(ids, &Map.get(instance_to_grp, &1)) |> Enum.reject(&is_nil/1)
          if resolved != [], do: {seat_id, resolved}

        _ ->
          nil
      end)
    else
      _ -> nil
    end
  end

  def extract_resolved_hand(_), do: nil

  defp extract_hand_arena_ids(nil, _seat_id, _cached_hand), do: nil

  defp extract_hand_arena_ids(game_state, seat_id, cached_hand) do
    zones = game_state["zones"] || []
    game_objects = game_state["gameObjects"] || []

    # Try to resolve from this message's own data first.
    instance_to_grp =
      case game_objects do
        [] -> %{}
        objs -> Map.new(objs, fn obj -> {obj["instanceId"], obj["grpId"]} end)
      end

    hand_instance_ids =
      Enum.find_value(zones, fn
        %{"type" => "ZoneType_Hand", "ownerSeatId" => ^seat_id, "objectInstanceIds" => ids} ->
          ids

        _ ->
          nil
      end)

    case {hand_instance_ids, instance_to_grp} do
      {ids, mapping} when is_list(ids) and map_size(mapping) > 0 ->
        resolved = Enum.map(ids, &Map.get(mapping, &1)) |> Enum.reject(&is_nil/1)
        if resolved != [], do: resolved, else: use_cached_hand(cached_hand, seat_id)

      _ ->
        # No resolvable hand in this message — fall back to cached hand
        # from a preceding GameStateMessage.
        use_cached_hand(cached_hand, seat_id)
    end
  end

  # The cached hand is `{seat_id, [arena_id, ...]}` from the most recent
  # GameStateMessage that had gameObjects. Only use it if the seat matches.
  defp use_cached_hand({cached_seat, hand}, seat_id) when cached_seat == seat_id, do: hand
  defp use_cached_hand(_, _), do: nil

  # ── Turn actions from GameStateMessage annotations ─────────────────
  #
  # Extracts meaningful game actions from GameStateMessage annotations.
  # Each ZoneTransfer with a category, DamageDealt, or ModifiedLife
  # annotation becomes a specific gameplay domain event. Low-value annotations
  # (phase changes, ability bookkeeping) are ignored.

  defp build_turn_actions(messages, match_id, occurred_at, match_context) do
    cached_objects = match_context[:last_hand_game_objects] || %{}

    messages
    |> Enum.flat_map(fn msg ->
      if game_state_message?(msg) do
        gsm = extract_game_state(msg)
        turn_info = gsm["turnInfo"] || %{}
        annotations = gsm["annotations"] || []
        game_objects = gsm["gameObjects"] || []

        # Build instance → grpId map from this message's objects
        local_objects = Map.new(game_objects, fn obj -> {obj["instanceId"], obj["grpId"]} end)

        # Merge with cached objects for resolution
        objects = Map.merge(cached_objects_to_map(cached_objects), local_objects)

        annotations
        |> Enum.flat_map(
          &annotation_to_turn_actions(&1, turn_info, match_id, occurred_at, objects)
        )
      else
        []
      end
    end)
  end

  defp cached_objects_to_map({_seat, _hand}), do: %{}
  defp cached_objects_to_map(map) when is_map(map), do: map
  defp cached_objects_to_map(_), do: %{}

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_ZoneTransfer"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         objects
       ) do
    details = ann["details"] || []
    category = find_detail_string(details, "category")
    instance_id = ann["affectedIds"] |> List.wrap() |> List.first()
    grp_id = Map.get(objects, instance_id)

    zone_from = find_detail_int(details, "zone_src")
    zone_to = find_detail_int(details, "zone_dest")

    common = %{
      mtga_match_id: match_id,
      turn_number: turn_info["turnNumber"],
      phase: turn_info["phase"],
      active_player: turn_info["activePlayer"],
      card_arena_id: grp_id,
      occurred_at: occurred_at
    }

    event =
      case category do
        "PlayLand" ->
          struct(LandPlayed, common)

        "CastSpell" ->
          struct(SpellCast, common)

        "Resolve" ->
          struct(SpellResolved, common)

        "Draw" ->
          struct(CardDrawn, common)

        "Destroy" ->
          struct(PermanentDestroyed, common)

        "Sacrifice" ->
          struct(
            ZoneChanged,
            Map.merge(common, %{
              reason: "sacrifice",
              zone_from: zone_name(zone_from),
              zone_to: zone_name(zone_to)
            })
          )

        "Exile" ->
          struct(CardExiled, common)

        "Discard" ->
          struct(
            ZoneChanged,
            Map.merge(common, %{
              reason: "discard",
              zone_from: zone_name(zone_from),
              zone_to: zone_name(zone_to)
            })
          )

        "Return" ->
          struct(
            ZoneChanged,
            Map.merge(common, %{
              reason: "return",
              zone_from: zone_name(zone_from),
              zone_to: zone_name(zone_to)
            })
          )

        "SBA_Damage" ->
          struct(PermanentDestroyed, common)

        "SBA_Deathtouch" ->
          struct(PermanentDestroyed, common)

        "Put" ->
          struct(
            ZoneChanged,
            Map.merge(common, %{
              reason: "put",
              zone_from: zone_name(zone_from),
              zone_to: zone_name(zone_to)
            })
          )

        _ ->
          nil
      end

    if event, do: [event], else: []
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_DamageDealt"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         objects
       ) do
    details = ann["details"] || []
    damage = find_detail_int(details, "damage")
    source_id = ann["affectorId"]
    grp_id = Map.get(objects, source_id)

    [
      %CombatDamageDealt{
        mtga_match_id: match_id,
        turn_number: turn_info["turnNumber"],
        phase: turn_info["phase"],
        active_player: turn_info["activePlayer"],
        card_arena_id: grp_id,
        amount: damage,
        occurred_at: occurred_at
      }
    ]
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_ModifiedLife"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         _objects
       ) do
    details = ann["details"] || []
    life_change = find_detail_int(details, "life")
    affected_player = ann["affectedIds"] |> List.wrap() |> List.first()

    [
      %LifeTotalChanged{
        mtga_match_id: match_id,
        turn_number: turn_info["turnNumber"],
        phase: turn_info["phase"],
        active_player: turn_info["activePlayer"],
        amount: life_change,
        affected_player: affected_player,
        occurred_at: occurred_at
      }
    ]
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_TokenCreated"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         objects
       ) do
    instance_id = ann["affectedIds"] |> List.wrap() |> List.first()
    grp_id = Map.get(objects, instance_id)

    [
      %TokenCreated{
        mtga_match_id: match_id,
        turn_number: turn_info["turnNumber"],
        phase: turn_info["phase"],
        active_player: turn_info["activePlayer"],
        card_arena_id: grp_id,
        occurred_at: occurred_at
      }
    ]
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_CounterAdded"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         objects
       ) do
    details = ann["details"] || []
    instance_id = ann["affectedIds"] |> List.wrap() |> List.first()
    grp_id = Map.get(objects, instance_id)
    amount = find_detail_int(details, "transaction_amount")

    [
      %CounterAdded{
        mtga_match_id: match_id,
        turn_number: turn_info["turnNumber"],
        phase: turn_info["phase"],
        active_player: turn_info["activePlayer"],
        card_arena_id: grp_id,
        amount: amount,
        occurred_at: occurred_at
      }
    ]
  end

  # All other annotation types — skip silently
  defp annotation_to_turn_actions(_ann, _turn_info, _match_id, _occurred_at, _objects), do: []

  # Detail extraction helpers
  defp find_detail_string(details, key) do
    Enum.find_value(details, fn
      %{"key" => ^key, "valueString" => [val | _]} -> val
      _ -> nil
    end)
  end

  defp find_detail_int(details, key) do
    Enum.find_value(details, fn
      %{"key" => ^key, "valueInt32" => [val | _]} -> val
      _ -> nil
    end)
  end

  # Map zone IDs to readable names (zone IDs are per-game, but
  # common zones have standard type names in the full state)
  defp zone_name(nil), do: nil
  defp zone_name(id) when is_integer(id) and id > 0, do: "zone_#{id}"
  defp zone_name(_), do: nil

  defp find_gre_message(messages, type) do
    Enum.find(messages, fn message -> message["type"] == type end)
  end

  # GREMessageType_QueuedGameStateMessage has the same payload shape
  # as GREMessageType_GameStateMessage. Both carry gameStateMessage.
  defp game_state_message?(%{"type" => "GREMessageType_GameStateMessage"}), do: true
  defp game_state_message?(%{"type" => "GREMessageType_QueuedGameStateMessage"}), do: true
  defp game_state_message?(_), do: false

  defp extract_game_state(msg) when is_map(msg), do: msg["gameStateMessage"]

  # Transforms a flat array of arena_ids [67810, 67810, 67810, 67810, ...]
  # into [%{arena_id: 67810, count: 4}, ...] sorted by arena_id.
  defp aggregate_card_list(ids) when is_list(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.map(fn {arena_id, count} -> %{arena_id: arena_id, count: count} end)
    |> Enum.sort_by(& &1.arena_id)
  end

  defp aggregate_card_list(_), do: []

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

  # BotDraftDraftPick and BotDraftDraftStatus carry a double-encoded
  # JSON string in the "request" field. Decode it to a map.
  defp decode_request_field(%{"request" => request}) when is_binary(request) do
    Jason.decode(request)
  end

  defp decode_request_field(_), do: :error

  # Extract set code from event names like "QuickDraft_FDN_20260323"
  # or "PremierDraft_LCI_20260401". The set code is the middle segment.
  defp extract_set_code(event_name) when is_binary(event_name) do
    case String.split(event_name, "_") do
      [_, set_code, _] -> set_code
      _ -> nil
    end
  end

  defp extract_set_code(_), do: nil

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
