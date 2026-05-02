defmodule Scry2.Crafts.Craft do
  @moduledoc """
  One detected wildcard craft — a spend attributed to a specific card.

  Derived from a pair of consecutive `Scry2.Collection.Snapshot` rows.
  The `from_snapshot_id` / `to_snapshot_id` columns retain the audit
  trail; `occurred_at_lower` / `occurred_at_upper` bracket the
  uncertainty window of when the craft actually happened (between
  the two snapshot timestamps).

  Idempotency: the unique index on `(to_snapshot_id, arena_id)` lets
  attribution replay over the same diff produce the same row.

  See ADR-037 for the attribution rule and schema rationale.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Scry2.Collection.Snapshot

  @type rarity :: :common | :uncommon | :rare | :mythic
  @type t :: %__MODULE__{}

  @rarities ~w(common uncommon rare mythic)

  @cast_fields [
    :occurred_at_lower,
    :occurred_at_upper,
    :arena_id,
    :rarity,
    :quantity,
    :from_snapshot_id,
    :to_snapshot_id
  ]

  @required_fields [
    :occurred_at_lower,
    :occurred_at_upper,
    :arena_id,
    :rarity,
    :quantity,
    :to_snapshot_id
  ]

  schema "crafts" do
    field :occurred_at_lower, :utc_datetime_usec
    field :occurred_at_upper, :utc_datetime_usec
    field :arena_id, :integer
    field :rarity, :string
    field :quantity, :integer

    belongs_to :from_snapshot, Snapshot, foreign_key: :from_snapshot_id
    belongs_to :to_snapshot, Snapshot, foreign_key: :to_snapshot_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(craft, attrs) do
    craft
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:rarity, @rarities)
    |> validate_number(:quantity, greater_than: 0)
    |> unique_constraint([:to_snapshot_id, :arena_id])
  end
end
