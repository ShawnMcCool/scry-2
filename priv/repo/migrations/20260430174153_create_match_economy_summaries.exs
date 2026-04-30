defmodule Scry2.Repo.Migrations.CreateMatchEconomySummaries do
  use Ecto.Migration

  def change do
    create table(:match_economy_summaries) do
      add :mtga_match_id, :string, null: false
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec

      add :pre_snapshot_id, references(:collection_snapshots, on_delete: :nilify_all), null: true
      add :post_snapshot_id, references(:collection_snapshots, on_delete: :nilify_all), null: true

      add :memory_gold_delta, :integer
      add :memory_gems_delta, :integer
      add :memory_wildcards_common_delta, :integer
      add :memory_wildcards_uncommon_delta, :integer
      add :memory_wildcards_rare_delta, :integer
      add :memory_wildcards_mythic_delta, :integer
      add :memory_vault_delta, :float

      add :log_gold_delta, :integer
      add :log_gems_delta, :integer
      add :log_wildcards_common_delta, :integer
      add :log_wildcards_uncommon_delta, :integer
      add :log_wildcards_rare_delta, :integer
      add :log_wildcards_mythic_delta, :integer

      add :diff_gold, :integer
      add :diff_gems, :integer
      add :diff_wildcards_common, :integer
      add :diff_wildcards_uncommon, :integer
      add :diff_wildcards_rare, :integer
      add :diff_wildcards_mythic, :integer

      add :reconciliation_state, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:match_economy_summaries, [:mtga_match_id])
    create index(:match_economy_summaries, [:ended_at])
  end
end
