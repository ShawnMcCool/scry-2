defmodule Scry2.Economy.EventEntry do
  @moduledoc """
  Schema for an event participation record.

  Seeded by `EventJoined`, enriched by `EventRewardClaimed` when the
  player finishes and claims prizes. The `event_name` + `joined_at`
  composite key ensures idempotent projection.

  ## Disposable

  Rebuilt from the domain event log via
  `Scry2.Economy.UpdateFromEvent.rebuild!/0`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "economy_event_entries" do
    field :player_id, :integer
    field :event_name, :string
    field :course_id, :string
    field :entry_currency_type, :string
    field :entry_fee, :integer
    field :joined_at, :utc_datetime
    field :final_wins, :integer
    field :final_losses, :integer
    field :gems_awarded, :integer
    field :gold_awarded, :integer
    field :boosters_awarded, :map
    field :claimed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :player_id,
      :event_name,
      :course_id,
      :entry_currency_type,
      :entry_fee,
      :joined_at,
      :final_wins,
      :final_losses,
      :gems_awarded,
      :gold_awarded,
      :boosters_awarded,
      :claimed_at
    ])
    |> validate_required([:event_name, :joined_at])
    |> unique_constraint([:player_id, :event_name, :joined_at])
  end
end
