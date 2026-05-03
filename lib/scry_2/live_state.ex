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

  alias Scry2.LiveState.{BoardSnapshot, RevealedCard, Snapshot}
  alias Scry2.Repo
  alias Scry2.Topics

  @enabled_settings_key "live_match_polling_enabled"
  @verbose_diagnostics_settings_key "live_state_verbose_diagnostics"

  @doc "PubSub topic for in-flight tick broadcasts."
  @spec updates_topic() :: String.t()
  def updates_topic, do: Topics.live_match_updates()

  @doc "PubSub topic for final-snapshot broadcasts."
  @spec final_topic() :: String.t()
  def final_topic, do: Topics.live_match_final()

  @doc """
  Settings key for the live-polling feature flag. Default behaviour is
  ON when the key is absent or set to anything truthy.
  """
  @spec enabled_settings_key() :: String.t()
  def enabled_settings_key, do: @enabled_settings_key

  @doc """
  Settings key for the verbose-diagnostics flag. Default behaviour is
  OFF — prod stays at WARNING for `:live_state` unless the user opts in.
  """
  @spec verbose_diagnostics_settings_key() :: String.t()
  def verbose_diagnostics_settings_key, do: @verbose_diagnostics_settings_key

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
  Read the verbose-diagnostics flag. Defaults to **false** — prod stays
  quiet (warning only). Flip on for debugging sessions to emit a
  per-tick info log line characterising both walker chains.
  """
  @spec verbose_diagnostics?() :: boolean()
  def verbose_diagnostics? do
    case Scry2.Settings.get(@verbose_diagnostics_settings_key) do
      true -> true
      "true" -> true
      _ -> false
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
        Phoenix.PubSub.broadcast(Scry2.PubSub, Topics.live_match_final(), {:final, snapshot})
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
    Phoenix.PubSub.broadcast(Scry2.PubSub, Topics.live_match_updates(), {:tick, payload})
  end

  # ── Chain 2 (board state) facade ───────────────────────────────────

  @doc """
  Persist the final board-state snapshot for a match. The parent
  `live_state_snapshots` row must already exist (Chain-1 wind-down
  has run and was successful) — `mtga_match_id` is the join key.

  Inserts the `live_match_board_snapshots` row plus all
  `live_match_revealed_cards` rows in one transaction. Re-running
  for the same match is rejected by the unique-on-snapshot index;
  the caller controls idempotency at the wind-down boundary.

  `attrs` mirrors the walker's `board_snapshot()` shape from the
  `Scry2.MtgaMemory` contract:

      %{
        zones: [%{seat_id: 2, zone_id: 4, arena_ids: [101, 102, ...]}, ...],
        reader_version: "x.y.z"
      }

  Returns the persisted `BoardSnapshot` (with `revealed_cards` not
  preloaded — call `get_board_by_match_id/1` for that). Broadcasts
  `{:final_board, snapshot}` on `live_match:board_final` after commit.
  """
  @spec record_final_board(String.t(), map()) ::
          {:ok, BoardSnapshot.t()}
          | {:error, :parent_snapshot_missing | Ecto.Changeset.t()}
  def record_final_board(mtga_match_id, attrs) when is_binary(mtga_match_id) and is_map(attrs) do
    case get_by_match_id(mtga_match_id) do
      nil ->
        {:error, :parent_snapshot_missing}

      %Snapshot{id: parent_id} ->
        zones = Map.get(attrs, :zones, [])

        snapshot_attrs = %{
          live_state_snapshot_id: parent_id,
          reader_version: Map.get(attrs, :reader_version, "unknown"),
          captured_at: Map.get(attrs, :captured_at) || DateTime.utc_now()
        }

        Repo.transaction(fn ->
          case %BoardSnapshot{}
               |> BoardSnapshot.changeset(snapshot_attrs)
               |> Repo.insert() do
            {:ok, board} ->
              insert_revealed_cards!(board.id, zones)
              board

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, board} ->
            Phoenix.PubSub.broadcast(
              Scry2.PubSub,
              Topics.live_match_board_final(),
              {:final_board, board}
            )

            {:ok, board}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Look up a board snapshot by its MTGA match id (join via the
  parent `live_state_snapshots` row). `revealed_cards` are NOT
  preloaded — use `get_revealed_cards_by_match_id/1` for the cards.
  """
  @spec get_board_by_match_id(String.t()) :: BoardSnapshot.t() | nil
  def get_board_by_match_id(mtga_match_id) when is_binary(mtga_match_id) do
    Repo.one(
      from b in BoardSnapshot,
        join: s in Snapshot,
        on: s.id == b.live_state_snapshot_id,
        where: s.mtga_match_id == ^mtga_match_id
    )
  end

  @doc """
  Return every revealed-card row for the given MTGA match id, ordered
  by (seat_id, zone_id, position) so callers can render directly.
  Returns `[]` when no board snapshot exists for the match.
  """
  @spec get_revealed_cards_by_match_id(String.t()) :: [RevealedCard.t()]
  def get_revealed_cards_by_match_id(mtga_match_id) when is_binary(mtga_match_id) do
    Repo.all(
      from c in RevealedCard,
        join: b in BoardSnapshot,
        on: b.id == c.board_snapshot_id,
        join: s in Snapshot,
        on: s.id == b.live_state_snapshot_id,
        where: s.mtga_match_id == ^mtga_match_id,
        order_by: [asc: c.seat_id, asc: c.zone_id, asc: c.position]
    )
  end

  defp insert_revealed_cards!(board_id, zones) do
    rows =
      for %{seat_id: seat_id, zone_id: zone_id, arena_ids: arena_ids} <- zones,
          {arena_id, position} <- Enum.with_index(arena_ids) do
        %{
          board_snapshot_id: board_id,
          seat_id: seat_id,
          zone_id: zone_id,
          arena_id: arena_id,
          position: position,
          inserted_at: now(),
          updated_at: now()
        }
      end

    case rows do
      [] ->
        :ok

      _ ->
        {_count, _} = Repo.insert_all(RevealedCard, rows)
        :ok
    end
  end

  defp now, do: DateTime.utc_now()
end
