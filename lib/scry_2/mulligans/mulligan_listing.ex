defmodule Scry2.Mulligans.MulliganListing do
  @moduledoc """
  Read-optimized projection row for the mulligans page.

  Each row represents one mulligan offer — a hand shown to the player
  with a keep/mulligan decision pending. The `event_name` is stamped
  from the corresponding `MatchCreated` event so the page can group
  by set/event without joining to the matches table.

  ## Decision inference

  The kept/mulliganed decision is NOT stored — it's inferred from the
  sequence by `MulligansHelpers.annotate_decisions/1`. The last offer
  in a match (by `occurred_at`) was kept; all prior were mulliganed.
  This keeps the projection simple and avoids needing to update rows
  when the sequence completes.

  ## Disposable

  This table can be dropped and rebuilt from the domain event log via
  `Scry2.Events.replay_projections!/0`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "mulligans_mulligan_listing" do
    field :player_id, :integer
    field :mtga_match_id, :string
    field :event_name, :string
    field :seat_id, :integer
    field :hand_size, :integer
    field :hand_arena_ids, :map
    field :land_count, :integer
    field :nonland_count, :integer
    field :total_cmc, :float
    field :cmc_distribution, :map
    field :color_distribution, :map
    field :card_names, :map
    field :occurred_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(listing, attrs) do
    listing
    |> cast(attrs, [
      :player_id,
      :mtga_match_id,
      :event_name,
      :seat_id,
      :hand_size,
      :hand_arena_ids,
      :land_count,
      :nonland_count,
      :total_cmc,
      :cmc_distribution,
      :color_distribution,
      :card_names,
      :occurred_at
    ])
    |> validate_required([:hand_size, :occurred_at])
    |> unique_constraint([:mtga_match_id, :occurred_at])
  end
end
