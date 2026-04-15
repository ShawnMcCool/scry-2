defmodule Scry2.Events.IdentifyDomainEvents.MatchRoom do
  @moduledoc """
  Translator for MatchGameRoomStateChangedEvent.

  Produces MatchCreated (stateType=Playing) and MatchCompleted
  (stateType=MatchCompleted) domain events from the matchmaking layer's
  game room state changes.
  """

  alias Scry2.Events.Match.{MatchCompleted, MatchCreated}
  alias Scry2.Events.TranslationWarning
  alias Scry2.MtgaLogIngestion.EventRecord

  @doc """
  Translates a MatchGameRoomStateChangedEvent record into domain events.

  Returns `{[domain_events], [warnings]}`.
  """
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

  # ── MatchCreated construction ───────────────────────────────────────

  defp maybe_build_match_created(info, record, self_user_id) do
    config = info["gameRoomConfig"] || %{}
    match_id = config["matchId"]
    reserved = config["reservedPlayers"] || []

    if is_binary(match_id) and match_id != "" do
      opponent = find_opponent(reserved, self_user_id)
      self_entry = find_self_entry(reserved, self_user_id)
      event_name = find_event_name(reserved, self_user_id)
      # NOTE: As of 2026-04, MTGA does not include opponent rank in
      # Player.log structured events. reservedPlayers only carries:
      # playerName, userId, platformId, systemSeatId, teamId, sessionId,
      # courseId, eventId. No other event type carries it either — the
      # rank shown in the MTGA UI comes from a channel not logged here.
      # These fields are wired up in case a future MTGA update adds it.
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
      game_results = build_game_results(result_list, self_team)

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

  # Per-game results from the matchmaking layer's finalMatchResult.
  # This is authoritative for win/loss — the GRE's GameCompleted event
  # is unreliable for conceded games (reports last game state, not the
  # concession outcome). `self_team` comes from reservedPlayers[].
  defp build_game_results(result_list, self_team) do
    result_list
    |> Enum.filter(fn row -> row["scope"] == "MatchScope_Game" end)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, index} ->
      %{
        game_number: index,
        winning_team_id: row["winningTeamId"],
        won: row["winningTeamId"] == self_team,
        reason: row["reason"]
      }
    end)
  end
end
