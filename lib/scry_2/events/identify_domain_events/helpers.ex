defmodule Scry2.Events.IdentifyDomainEvents.Helpers do
  @moduledoc """
  Shared utility functions for the IdentifyDomainEvents translator family.

  These helpers are used by two or more translator modules (MatchRoom,
  ConnectResp, GameStateMessage, ClientToGre) and are collected here to
  avoid duplication.
  """

  # ── GRE message classification ───────────────────────────────────────

  @doc "Returns true if the GRE message is a GameStateMessage or QueuedGameStateMessage."
  def game_state_message?(%{"type" => "GREMessageType_GameStateMessage"}), do: true
  def game_state_message?(%{"type" => "GREMessageType_QueuedGameStateMessage"}), do: true
  def game_state_message?(_), do: false

  @doc "Finds the first GRE message of the given type in the batch."
  def find_gre_message(messages, type) do
    Enum.find(messages, fn message -> message["type"] == type end)
  end

  @doc "Extracts the gameStateMessage payload from a GRE message map."
  def extract_game_state(msg) when is_map(msg), do: msg["gameStateMessage"]

  @doc """
  Resolves the player's seat from a GRE message batch.

  GreToClientEvent is the player's client feed. Messages addressed to
  a single seat (ConnectResp, GameStateMessage) carry the player's
  seat in systemSeatIds. Broadcast messages (DieRollResultsResp)
  carry all seats. We find the first single-seat message to determine
  the player's seat. Falls back to 1 defensively (should not happen
  in practice — ConnectResp always precedes other messages).
  """
  def resolve_player_seat(messages) when is_list(messages) do
    Enum.find_value(messages, 1, fn
      %{"systemSeatIds" => [seat_id]} -> seat_id
      _ -> nil
    end)
  end

  @doc "Extracts the match ID from a GRE message batch by scanning GameStateMessages."
  def extract_match_id(messages) do
    Enum.find_value(messages, fn msg ->
      if game_state_message?(msg) do
        get_in(extract_game_state(msg), ["gameInfo", "matchID"])
      end
    end)
  end

  # ── Zone helpers ─────────────────────────────────────────────────────

  @doc "Maps zone IDs to readable names."
  def zone_name(nil), do: nil
  def zone_name(id) when is_integer(id) and id > 0, do: "zone_#{id}"
  def zone_name(_), do: nil

  # ── Annotation detail extraction ─────────────────────────────────────

  @doc "Finds a string detail value by key from an annotation details list."
  def find_detail_string(details, key) do
    Enum.find_value(details, fn
      %{"key" => ^key, "valueString" => [val | _]} -> val
      _ -> nil
    end)
  end

  @doc "Finds an integer detail value by key from an annotation details list."
  def find_detail_int(details, key) do
    Enum.find_value(details, fn
      %{"key" => ^key, "valueInt32" => [val | _]} -> val
      _ -> nil
    end)
  end

  # ── Card list aggregation ─────────────────────────────────────────────

  @doc """
  Transforms a flat array of arena_ids [67810, 67810, 67810, 67810, ...]
  into [%{arena_id: 67810, count: 4}, ...] sorted by arena_id.
  """
  def aggregate_card_list(ids) when is_list(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.map(fn {arena_id, count} -> %{arena_id: arena_id, count: count} end)
    |> Enum.sort_by(& &1.arena_id)
  end

  def aggregate_card_list(_), do: []

  # ── Cached objects map ────────────────────────────────────────────────

  @doc "Coerces the cached_objects value to a map (handles nil/non-map gracefully)."
  def cached_objects_to_map(map) when is_map(map), do: map
  def cached_objects_to_map(_), do: %{}
end
