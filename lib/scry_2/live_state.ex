defmodule Scry2.LiveState do
  @moduledoc """
  Live in-match state captured by polling MTGA's process memory
  (Chain 1: rank, screen-name, commander grpIds).

  Two responsibilities, separated by file:

    * **Persistence facade** (this module) — `record_final/1`,
      `get_by_match_id/1`, broadcast helpers.
    * **State machine** (`Scry2.LiveState.Server`) — IDLE → POLLING
      → WINDING_DOWN GenServer that subscribes to `domain:events`
      and calls `Scry2.MtgaMemory.impl().walk_match_info/1` on a
      timer.

  See `decisions/research/2026-04-30-001-opponent-game-state-memory-read.md`
  for the rationale.

  ## PubSub topics

    * `live_match:updates` — broadcast every poll tick during an
      active match. Payload: `{:tick, %{mtga_match_id, local,
      opponent, format, ...}}` mirroring the `walk_match_info`
      shape, plus `:reader_version` and `:captured_at`.
    * `live_match:final` — broadcast once per match when the state
      machine transitions to WINDING_DOWN and the final snapshot
      has been persisted. Payload: `{:final, %Snapshot{}}`.
  """

  import Ecto.Query, only: [from: 2]

  alias Scry2.LiveState.Snapshot
  alias Scry2.Repo

  @updates_topic "live_match:updates"
  @final_topic "live_match:final"
  @enabled_settings_key "live_match_polling_enabled"

  @doc "PubSub topic for in-flight tick broadcasts."
  @spec updates_topic() :: String.t()
  def updates_topic, do: @updates_topic

  @doc "PubSub topic for final-snapshot broadcasts."
  @spec final_topic() :: String.t()
  def final_topic, do: @final_topic

  @doc """
  Settings key for the live-polling feature flag. Default behaviour is
  ON when the key is absent or set to anything truthy.
  """
  @spec enabled_settings_key() :: String.t()
  def enabled_settings_key, do: @enabled_settings_key

  @doc """
  Read the current value of the live-polling feature flag. Defaults to
  true when the setting is absent (e.g. fresh install).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Scry2.Settings.get(@enabled_settings_key) do
      nil -> true
      true -> true
      "true" -> true
      false -> false
      "false" -> false
      _ -> true
    end
  end

  @doc """
  Persist the final snapshot for a match (or upsert if one already
  exists for the same `mtga_match_id`). Broadcasts on `live_match:final`
  on success.

  `attrs` matches the `Scry2.LiveState.Snapshot` field set, with the
  Mtga match ID supplied separately for clarity at call sites — the
  state machine knows the match ID before it knows the snapshot.
  """
  @spec record_final(String.t(), map()) :: {:ok, Snapshot.t()} | {:error, Ecto.Changeset.t()}
  def record_final(mtga_match_id, attrs) when is_binary(mtga_match_id) do
    full_attrs =
      attrs
      |> Map.put(:mtga_match_id, mtga_match_id)
      |> Map.put_new(:captured_at, DateTime.utc_now())

    existing = get_by_match_id(mtga_match_id) || %Snapshot{}

    case existing |> Snapshot.changeset(full_attrs) |> Repo.insert_or_update() do
      {:ok, snapshot} ->
        Phoenix.PubSub.broadcast(Scry2.PubSub, @final_topic, {:final, snapshot})
        {:ok, snapshot}

      {:error, _} = err ->
        err
    end
  end

  @doc "Look up a final snapshot by MTGA match id; returns `nil` if absent."
  @spec get_by_match_id(String.t()) :: Snapshot.t() | nil
  def get_by_match_id(mtga_match_id) when is_binary(mtga_match_id) do
    Repo.one(from s in Snapshot, where: s.mtga_match_id == ^mtga_match_id)
  end

  @doc """
  Broadcast a poll-tick update on `live_match:updates`. The state
  machine calls this every ~500 ms during an active match; nothing
  is persisted at this stage — the tick is purely for UI subscribers.
  """
  @spec broadcast_tick(map()) :: :ok
  def broadcast_tick(payload) when is_map(payload) do
    Phoenix.PubSub.broadcast(Scry2.PubSub, @updates_topic, {:tick, payload})
  end
end
