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

  alias Scry2.Events.{DeckSubmitted, MatchCompleted, MatchCreated}
  alias Scry2.MtgaLogIngestion.EventRecord

  # ── Event type registry (ADR-020) ──────────────────────────────────
  #
  # Every raw MTGA event type must be either handled (produces domain
  # events) or explicitly ignored (known but uninteresting). Types not
  # in either set are "unrecognized" and surfaced in the dashboard.

  @handled_event_types MapSet.new([
                         "MatchGameRoomStateChangedEvent",
                         "GreToClientEvent"
                       ])

  @ignored_event_types MapSet.new([
                         # GRE client messages — high-volume UI/input traffic, no domain value
                         "ClientToGreuimessage",
                         "ClientToGremessage",
                         # Lobby/session lifecycle — no actionable domain events (yet)
                         "AuthenticateResponse",
                         "EventJoin",
                         "EventGetCoursesV2",
                         "EventGetActiveMatches",
                         "EventEnterPairing",
                         # Deck management — lobby-side, superseded by ConnectResp deck data
                         "DeckUpsertDeckV2",
                         "EventSetDeckV2",
                         "DeckGetDeckSummariesV2",
                         # Rank queries — future domain events TBD
                         "RankGetCombinedRankInfo",
                         "RankGetSeasonAndRankDetails",
                         # UI state / rewards / system — no domain value
                         "GraphGetGraphState",
                         "QuestGetQuests",
                         "PeriodicRewardsGetStatus",
                         "StartHook",
                         "GetFormats",
                         "LogBusinessEvents"
                       ])

  @known_event_types MapSet.union(@handled_event_types, @ignored_event_types)

  @doc "Returns the set of all recognized raw MTGA event types."
  @spec known_event_types() :: MapSet.t(String.t())
  def known_event_types, do: @known_event_types

  @doc "Returns true if the event type has an explicit handler or ignore clause."
  @spec recognized?(String.t()) :: boolean()
  def recognized?(event_type), do: MapSet.member?(@known_event_types, event_type)

  @type self_user_id :: String.t() | nil

  @doc """
  Translates a raw MTGA event record into a (possibly empty) list of
  domain event structs.

  `self_user_id` is the user's MTGA Wizards ID, used to distinguish
  self from opponent in `reservedPlayers[]`. When nil, the translator
  falls back to assuming `systemSeatId: 1` is the local player.
  """
  @spec translate(%EventRecord{}, self_user_id()) :: [struct()]

  # MatchGameRoomStateChangedEvent produces different domain events based
  # on the nested stateType. Playing = match just created. MatchCompleted
  # = match just finished. Other stateTypes (Connected, ConnectingToGRE,
  # etc.) produce no domain events.
  def translate(%EventRecord{event_type: "MatchGameRoomStateChangedEvent"} = record, self_user_id) do
    with {:ok, payload} <- Jason.decode(record.raw_json),
         {:ok, info} <- extract_game_room_info(payload) do
      case info["stateType"] do
        "MatchGameRoomStateType_Playing" ->
          maybe_build_match_created(info, record, self_user_id)

        "MatchGameRoomStateType_MatchCompleted" ->
          maybe_build_match_completed(info, record, self_user_id)

        _ ->
          []
      end
    else
      _ -> []
    end
  end

  # GreToClientEvent carries GRE messages in a nested array. A single
  # raw event can produce multiple domain events — e.g. a ConnectResp
  # (deck submission) and a GameStateMessage (game completion) in the
  # same batch.
  def translate(%EventRecord{event_type: "GreToClientEvent"} = record, _self_user_id) do
    occurred_at = record.mtga_timestamp || record.inserted_at

    with {:ok, payload} <- Jason.decode(record.raw_json),
         messages when is_list(messages) <-
           get_in(payload, ["greToClientEvent", "greToClientMessages"]) do
      match_id = extract_match_id_from_gre(messages)

      [
        maybe_build_deck_submitted(messages, match_id, occurred_at),
        maybe_build_game_completed(messages, match_id, occurred_at)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  # Fall-through: raw event types we don't translate (yet or ever)
  # produce no domain events. The raw event is still preserved in
  # mtga_logs_events for future reprocessing via retranslate_from_raw!/0.
  def translate(%EventRecord{}, _self_user_id), do: []

  # ── MatchCreated construction ───────────────────────────────────────

  defp maybe_build_match_created(info, record, self_user_id) do
    config = info["gameRoomConfig"] || %{}
    match_id = config["matchId"]
    reserved = config["reservedPlayers"] || []

    if is_binary(match_id) and match_id != "" do
      opponent = find_opponent(reserved, self_user_id)
      event_name = find_event_name(reserved, self_user_id)

      [
        %MatchCreated{
          mtga_match_id: match_id,
          event_name: event_name,
          opponent_screen_name: opponent["playerName"],
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

      [
        %MatchCompleted{
          mtga_match_id: match_id,
          occurred_at: record.mtga_timestamp || record.inserted_at,
          won: winning_team == self_team,
          num_games: num_games,
          reason: final_result["matchCompletedReason"]
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

  # ── GRE message extraction ────────────────────────────────────────────
  #
  # GreToClientEvent.greToClientMessages[] is a flat array of typed
  # messages. Each message has a "type" discriminator. These helpers
  # find specific message types and extract domain events from them.

  defp extract_match_id_from_gre(messages) do
    Enum.find_value(messages, fn
      %{"type" => "GREMessageType_GameStateMessage", "gameStateMessage" => gsm} ->
        get_in(gsm, ["gameInfo", "matchID"])

      _ ->
        nil
    end)
  end

  # ConnectResp carries the deck list as flat arrays of arena_ids (one
  # entry per copy). Aggregate into [%{arena_id, count}] shape.
  defp maybe_build_deck_submitted(messages, match_id, occurred_at)
       when is_binary(match_id) do
    case find_gre_message(messages, "GREMessageType_ConnectResp") do
      %{"connectResp" => connect_resp} = message ->
        deck_message = connect_resp["deckMessage"] || %{}
        seat_id = message["systemSeatIds"] |> List.first()

        main_deck = aggregate_card_list(deck_message["deckCards"] || [])
        sideboard = aggregate_card_list(deck_message["sideboardCards"] || [])

        %DeckSubmitted{
          mtga_match_id: match_id,
          mtga_deck_id: "#{match_id}:seat#{seat_id}",
          main_deck: main_deck,
          sideboard: sideboard,
          occurred_at: occurred_at
        }

      _ ->
        nil
    end
  end

  defp maybe_build_deck_submitted(_messages, _match_id, _occurred_at), do: nil

  # Stub — will be implemented when a real game-complete fixture is
  # available. Needs a GameStateMessage with matchState:
  # "MatchState_GameComplete" and results data.
  defp maybe_build_game_completed(_messages, _match_id, _occurred_at), do: nil

  defp find_gre_message(messages, type) do
    Enum.find(messages, fn message -> message["type"] == type end)
  end

  # Transforms a flat array of arena_ids [67810, 67810, 67810, 67810, ...]
  # into [%{arena_id: 67810, count: 4}, ...] sorted by arena_id.
  defp aggregate_card_list(ids) when is_list(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.map(fn {arena_id, count} -> %{arena_id: arena_id, count: count} end)
    |> Enum.sort_by(& &1.arena_id)
  end

  defp aggregate_card_list(_), do: []
end
