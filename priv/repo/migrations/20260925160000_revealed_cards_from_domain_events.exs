defmodule Scry2.Repo.Migrations.RevealedCardsFromDomainEvents do
  @moduledoc """
  ADR-047 — revealed cards move from the memory walker to the domain
  event log.

  Creates `matches_revealed_cards` (a projection, rebuildable from
  `domain_events` at any time) and drops the two memory-derived tables
  it replaces.

  The dropped rows are not migrated. They are superseded by a replay
  over the same matches from authoritative GRE data, and are known to be
  contaminated — 36 of the 1,941 local-seat hand rows are cards absent
  from that match's own submitted decklist. The database was backed up
  through Fae immediately before this migration was authored.
  """
  use Ecto.Migration

  def up do
    create table(:matches_revealed_cards) do
      add :mtga_match_id, :string, null: false
      add :seat_id, :integer, null: false
      add :arena_id, :integer, null: false

      # Semantic zone slug from Scry2.Events.IdentifyDomainEvents.ZoneTable
      # ("battlefield", "hand", "graveyard", "exile", …). The zone we most
      # recently saw this card in — the projection is cumulative across the
      # whole match, unlike the single-instant board snapshot it replaces.
      add :current_zone, :string

      # How many times this card's identity was disclosed in this match.
      # Distinct copies of the same card collapse onto one row.
      add :copies_seen, :integer, null: false, default: 1

      add :first_seen_turn, :integer
      add :last_seen_turn, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:matches_revealed_cards, [:mtga_match_id, :seat_id, :arena_id])
    create index(:matches_revealed_cards, [:mtga_match_id])
    create index(:matches_revealed_cards, [:mtga_match_id, :current_zone])

    # Retired: Chain-2 memory board reading. See ADR-047.
    drop table(:live_match_revealed_cards)
    drop table(:live_match_board_snapshots)
  end

  def down do
    create table(:live_match_board_snapshots) do
      add :live_state_snapshot_id,
          references(:live_state_snapshots, on_delete: :delete_all),
          null: false

      add :reader_version, :string, null: false
      add :captured_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:live_match_board_snapshots, [:live_state_snapshot_id])

    create table(:live_match_revealed_cards) do
      add :board_snapshot_id,
          references(:live_match_board_snapshots, on_delete: :delete_all),
          null: false

      add :seat_id, :integer
      add :zone_id, :integer
      add :arena_id, :integer
      add :position, :integer, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create index(:live_match_revealed_cards, [:board_snapshot_id])

    drop table(:matches_revealed_cards)
  end
end
