defmodule Scry2.Repo.Migrations.CreateLiveStateSnapshots do
  use Ecto.Migration

  @moduledoc """
  Final-snapshot table for `Scry2.LiveState`.

  One row per match, written when the live-polling state machine
  transitions POLLING → WINDING_DOWN. Captures the rank, screen name,
  and commander identities visible in MTGA's process memory at the
  end of the match — data that is not available from the
  `Player.log` event stream (see project memory
  `project_mtga_no_opponent_rank.md`).

  `mtga_match_id` is the join key back to `matches_matches`; we keep
  it as a string column rather than a FK because LiveState writes
  before the Matches projection has necessarily finished its own
  end-of-match handling.
  """

  def change do
    create table(:live_state_snapshots) do
      add :mtga_match_id, :string, null: false

      # Local player.
      add :local_screen_name, :string
      add :local_seat_id, :integer
      add :local_team_id, :integer
      add :local_ranking_class, :integer
      add :local_ranking_tier, :integer
      add :local_mythic_percentile, :integer
      add :local_mythic_placement, :integer
      # JSON array of arena_id ints.
      add :local_commander_grp_ids, :text

      # Opponent.
      add :opponent_screen_name, :string
      add :opponent_seat_id, :integer
      add :opponent_team_id, :integer
      add :opponent_ranking_class, :integer
      add :opponent_ranking_tier, :integer
      add :opponent_mythic_percentile, :integer
      add :opponent_mythic_placement, :integer
      add :opponent_commander_grp_ids, :text

      # Snapshot context.
      add :format, :integer
      add :variant, :integer
      add :session_type, :integer
      add :is_practice_game, :boolean, default: false, null: false
      add :is_private_game, :boolean, default: false, null: false

      # Provenance.
      add :reader_version, :string, null: false
      add :captured_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:live_state_snapshots, [:mtga_match_id])
  end
end
