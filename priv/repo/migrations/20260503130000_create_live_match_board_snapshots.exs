defmodule Scry2.Repo.Migrations.CreateLiveMatchBoardSnapshots do
  use Ecto.Migration

  @moduledoc """
  Per-match Chain-2 board-state snapshot sibling table to
  `live_state_snapshots`.

  Captures the cards visible in each (seat, zone) at the moment
  `Scry2.LiveState.Server` transitions POLLING → WINDING_DOWN.
  Cards themselves live in `live_match_revealed_cards` (created by
  the next migration); this table just holds the per-match metadata
  + provenance and acts as the FK target.

  One row per match. Cascade-deleted when the parent
  `live_state_snapshots` row is deleted.

  See `specs/2026-05-03-chain-2-board-state-design.md`.
  """

  def change do
    create table(:live_match_board_snapshots) do
      add :live_state_snapshot_id,
          references(:live_state_snapshots, on_delete: :delete_all),
          null: false

      add :reader_version, :string, null: false
      add :captured_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:live_match_board_snapshots, [:live_state_snapshot_id])
  end
end
