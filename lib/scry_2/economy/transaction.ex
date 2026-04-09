defmodule Scry2.Economy.Transaction do
  @moduledoc """
  Schema for a single economy delta (gold/gems gained or spent).

  Captured from `InventoryChanged` events. Each row records one
  resource change with its source event and running balance.

  ## Disposable

  Rebuilt from the domain event log via
  `Scry2.Economy.EconomyProjection.rebuild!/0`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "economy_transactions" do
    field :player_id, :integer
    field :source, :string
    field :source_id, :string
    field :gold_delta, :integer
    field :gems_delta, :integer
    field :boosters, :map
    field :gold_balance, :integer
    field :gems_balance, :integer
    field :occurred_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :player_id,
      :source,
      :source_id,
      :gold_delta,
      :gems_delta,
      :boosters,
      :gold_balance,
      :gems_balance,
      :occurred_at
    ])
    |> validate_required([:source, :occurred_at])
  end
end
