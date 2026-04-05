defmodule Scry2.Events.Translator do
  @moduledoc """
  Pipeline stage 07 — the anti-corruption layer between MTGA's wire
  format and scry_2's domain model (ADR-018).

  ## Contract

  | | |
  |---|---|
  | **Input**  | `%Scry2.MtgaLogs.EventRecord{}` + `self_user_id` (nil for seat-1 fallback) |
  | **Output** | List of domain event structs (`%Scry2.Events.*{}`); empty list if nothing applies |
  | **Nature** | Pure — no DB, no GenServer, no side effects |
  | **Called from** | `Scry2.Events.IngestionWorker` |
  | **Hands off to** | `Scry2.Events.append!/2` (persists + broadcasts each struct) |

  ## The ACL principle

  The Translator is the **only** module in scry_2 that understands
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

  alias Scry2.Events.{MatchCompleted, MatchCreated}
  alias Scry2.MtgaLogs.EventRecord

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
          started_at: record.mtga_timestamp
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
          ended_at: record.mtga_timestamp,
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
end
