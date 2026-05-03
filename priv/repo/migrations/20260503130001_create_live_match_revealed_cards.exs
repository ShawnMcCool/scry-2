defmodule Scry2.Repo.Migrations.CreateLiveMatchRevealedCards do
  use Ecto.Migration

  @moduledoc """
  Normalized per-(seat, zone, arena_id) card table for Chain-2 board
  snapshots.

  One row per visible card. v1 only emits Battlefield-zone rows
  (`zone_id == 4`) — other zones land once `CardLayoutData` drilling
  is wired in the walker.

  `position` preserves MTGA's storage order so rendering can show the
  cards in play order. `arena_id` is indexed for cross-match queries
  ("opponents who revealed this card") which v1 doesn't surface but
  the schema supports.

  Cascade-deleted with the parent `live_match_board_snapshots` row.

  See `specs/2026-05-03-chain-2-board-state-design.md`.
  """

  def change do
    create table(:live_match_revealed_cards) do
      add :board_snapshot_id,
          references(:live_match_board_snapshots, on_delete: :delete_all),
          null: false

      add :seat_id, :integer, null: false
      add :zone_id, :integer, null: false
      add :arena_id, :integer, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:live_match_revealed_cards, [:board_snapshot_id])
    create index(:live_match_revealed_cards, [:arena_id])
  end
end
