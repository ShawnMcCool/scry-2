defmodule Scry2.Ranks.Snapshot do
  @moduledoc """
  Schema for a point-in-time rank snapshot.

  Each row records the player's constructed and limited rank at the
  moment MTGA reported it. Used for rank progression display.

  ## Disposable

  This table can be dropped and rebuilt from the domain event log via
  `Scry2.Ranks.UpdateFromEvent.rebuild!/0`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "ranks_snapshots" do
    field :player_id, :integer
    field :constructed_class, :string
    field :constructed_level, :integer
    field :constructed_step, :integer
    field :constructed_matches_won, :integer
    field :constructed_matches_lost, :integer
    field :limited_class, :string
    field :limited_level, :integer
    field :limited_step, :integer
    field :limited_matches_won, :integer
    field :limited_matches_lost, :integer
    field :season_ordinal, :integer
    field :occurred_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :player_id,
      :constructed_class,
      :constructed_level,
      :constructed_step,
      :constructed_matches_won,
      :constructed_matches_lost,
      :limited_class,
      :limited_level,
      :limited_step,
      :limited_matches_won,
      :limited_matches_lost,
      :season_ordinal,
      :occurred_at
    ])
    |> validate_required([:occurred_at])
  end
end
