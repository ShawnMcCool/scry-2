defmodule Scry2.MatchEconomy.Summary do
  @moduledoc """
  Per-match economy projection: memory deltas, log deltas, and per-currency
  diffs (memory − log). One row per match. See ADR-036.

  Disposable projection — derivable from the linked `Collection.Snapshot`
  rows plus `Economy.Transaction` / `Economy.InventorySnapshot` history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @reconciliation_states ~w(complete log_only incomplete)

  @cast_fields [
    :mtga_match_id,
    :started_at,
    :ended_at,
    :pre_snapshot_id,
    :post_snapshot_id,
    :memory_gold_delta,
    :memory_gems_delta,
    :memory_wildcards_common_delta,
    :memory_wildcards_uncommon_delta,
    :memory_wildcards_rare_delta,
    :memory_wildcards_mythic_delta,
    :memory_vault_delta,
    :log_gold_delta,
    :log_gems_delta,
    :log_wildcards_common_delta,
    :log_wildcards_uncommon_delta,
    :log_wildcards_rare_delta,
    :log_wildcards_mythic_delta,
    :diff_gold,
    :diff_gems,
    :diff_wildcards_common,
    :diff_wildcards_uncommon,
    :diff_wildcards_rare,
    :diff_wildcards_mythic,
    :reconciliation_state
  ]

  @required [:mtga_match_id, :reconciliation_state]

  schema "match_economy_summaries" do
    field :mtga_match_id, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    belongs_to :pre_snapshot, Scry2.Collection.Snapshot
    belongs_to :post_snapshot, Scry2.Collection.Snapshot

    field :memory_gold_delta, :integer
    field :memory_gems_delta, :integer
    field :memory_wildcards_common_delta, :integer
    field :memory_wildcards_uncommon_delta, :integer
    field :memory_wildcards_rare_delta, :integer
    field :memory_wildcards_mythic_delta, :integer
    field :memory_vault_delta, :float

    field :log_gold_delta, :integer
    field :log_gems_delta, :integer
    field :log_wildcards_common_delta, :integer
    field :log_wildcards_uncommon_delta, :integer
    field :log_wildcards_rare_delta, :integer
    field :log_wildcards_mythic_delta, :integer

    field :diff_gold, :integer
    field :diff_gems, :integer
    field :diff_wildcards_common, :integer
    field :diff_wildcards_uncommon, :integer
    field :diff_wildcards_rare, :integer
    field :diff_wildcards_mythic, :integer

    field :reconciliation_state, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, @cast_fields)
    |> validate_required(@required)
    |> validate_inclusion(:reconciliation_state, @reconciliation_states)
    |> unique_constraint(:mtga_match_id)
  end

  @doc "All allowed reconciliation_state values."
  def reconciliation_states, do: @reconciliation_states
end
