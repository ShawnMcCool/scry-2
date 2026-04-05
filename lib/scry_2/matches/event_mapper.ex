defmodule Scry2.Matches.EventMapper do
  @moduledoc """
  Pipeline stage 08 — pure functions that transform decoded MTGA event
  payloads into `Scry2.Matches` upsert attrs.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `%Scry2.MtgaLogs.EventRecord{}` loaded from the DB |
  | **Output** | `{:ok, attrs}` to feed `Scry2.Matches.upsert_match!/1`, or `:ignore` |
  | **Nature** | Pure — no DB, no GenServer, no side effects |
  | **Called from** | `Scry2.Matches.Ingester.handle_info/2` (stage 07 → 08) |
  | **Hands off to** | `Scry2.Matches.upsert_match!/1` (stage 08 → 09) |

  Each public function handles one MTGA event type. The naming
  convention is `<target>_attrs_from_<event_type_snake_case>/arity` so
  you can grep for an event type name and find the mapper instantly.

  ## Self vs opponent

  `reservedPlayers[]` in match events contains both the local player
  and the opponent. The mapper distinguishes them using the user's own
  Wizards ID (`self_user_id`). When the ID is nil, it falls back to
  `systemSeatId: 1` (normally the local player — see
  `defaults/scry_2.toml` > `mtga_logs.self_user_id`).

  ## Scope

  Handles `MatchGameRoomStateChangedEvent` with state=Playing only.
  Match completion, per-game results, and deck submissions are
  follow-up work tracked in `TODO.md` > "Match ingestion follow-ups".
  """

  alias Scry2.MtgaLogs.EventRecord

  @type self_user_id :: String.t() | nil

  @doc """
  Maps a `MatchGameRoomStateChangedEvent` payload into match upsert
  attrs. Returns `:ignore` when the event is not a match-creation
  transition (we only handle the Playing state for now — MatchCompleted
  finalization is future work).
  """
  @spec match_attrs_from_game_room_state_changed(%EventRecord{}, self_user_id()) ::
          {:ok, map()} | :ignore
  def match_attrs_from_game_room_state_changed(%EventRecord{} = record, self_user_id) do
    with {:ok, payload} <- Jason.decode(record.raw_json),
         {:ok, info} <- extract_game_room_info(payload),
         %{"gameRoomConfig" => config, "stateType" => "MatchGameRoomStateType_Playing"} <- info,
         %{"matchId" => match_id, "reservedPlayers" => reserved} <- config,
         true <- is_binary(match_id) and match_id != "" do
      opponent = find_opponent(reserved, self_user_id)
      event_name = find_event_name(reserved, self_user_id)

      {:ok,
       %{
         mtga_match_id: match_id,
         event_name: event_name,
         format: nil,
         opponent_screen_name: opponent["playerName"],
         started_at: record.mtga_timestamp
       }}
    else
      _ -> :ignore
    end
  end

  # ── Private helpers ────────────────────────────────────────────────

  defp extract_game_room_info(%{"matchGameRoomStateChangedEvent" => %{"gameRoomInfo" => info}}),
    do: {:ok, info}

  defp extract_game_room_info(_), do: :error

  # Find the opponent in reservedPlayers[] using the user's Wizards ID.
  # Falls back to "whoever isn't seat 1" when self_user_id is nil.
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
    self_entry =
      case self_user_id do
        id when is_binary(id) ->
          Enum.find(reserved, fn player -> player["userId"] == id end)

        nil ->
          Enum.find(reserved, fn player -> player["systemSeatId"] == 1 end)
      end

    case self_entry do
      %{"eventId" => event_id} when is_binary(event_id) -> event_id
      _ -> nil
    end
  end
end
