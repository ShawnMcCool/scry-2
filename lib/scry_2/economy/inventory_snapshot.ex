defmodule Scry2.Economy.InventorySnapshot do
  @moduledoc """
  Schema for a point-in-time inventory balance snapshot.

  Captured from `InventoryUpdated` events (login and reward claims).

  ## Disposable

  Rebuilt from the domain event log via
  `Scry2.Economy.UpdateFromEvent.rebuild!/0`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "economy_inventory_snapshots" do
    field :player_id, :integer
    field :gold, :integer
    field :gems, :integer
    field :wildcards_common, :integer
    field :wildcards_uncommon, :integer
    field :wildcards_rare, :integer
    field :wildcards_mythic, :integer
    field :vault_progress, :float
    field :occurred_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :player_id,
      :gold,
      :gems,
      :wildcards_common,
      :wildcards_uncommon,
      :wildcards_rare,
      :wildcards_mythic,
      :vault_progress,
      :occurred_at
    ])
    |> validate_required([:occurred_at])
  end
end
