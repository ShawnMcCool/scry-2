defmodule Scry2.Repo.Migrations.CreateEconomyTables do
  use Ecto.Migration

  def change do
    create table(:economy_event_entries) do
      add :player_id, :integer
      add :event_name, :string, null: false
      add :course_id, :string
      add :entry_currency_type, :string
      add :entry_fee, :integer
      add :joined_at, :utc_datetime, null: false
      # Filled when EventRewardClaimed arrives:
      add :final_wins, :integer
      add :final_losses, :integer
      add :gems_awarded, :integer
      add :gold_awarded, :integer
      add :boosters_awarded, :map
      add :claimed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:economy_event_entries, [:player_id])
    create index(:economy_event_entries, [:event_name])
    create unique_index(:economy_event_entries, [:player_id, :event_name, :joined_at])

    create table(:economy_inventory_snapshots) do
      add :player_id, :integer
      add :gold, :integer
      add :gems, :integer
      add :wildcards_common, :integer
      add :wildcards_uncommon, :integer
      add :wildcards_rare, :integer
      add :wildcards_mythic, :integer
      add :vault_progress, :float
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:economy_inventory_snapshots, [:player_id])
    create index(:economy_inventory_snapshots, [:occurred_at])

    create table(:economy_transactions) do
      add :player_id, :integer
      add :source, :string, null: false
      add :source_id, :string
      add :gold_delta, :integer
      add :gems_delta, :integer
      add :boosters, :map
      add :gold_balance, :integer
      add :gems_balance, :integer
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:economy_transactions, [:player_id])
    create index(:economy_transactions, [:occurred_at])
  end
end
