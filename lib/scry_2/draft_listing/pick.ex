defmodule Scry2.DraftListing.Pick do
  use Ecto.Schema
  import Ecto.Changeset

  schema "drafts_picks" do
    field :pack_number, :integer
    field :pick_number, :integer
    # References Scry2.Cards.Card.arena_id by value — cross-context per
    # ADR-014. Never a belongs_to.
    field :picked_arena_id, :integer
    field :pack_arena_ids, :map
    field :pool_arena_ids, :map
    field :picked_at, :utc_datetime

    belongs_to :draft, Scry2.DraftListing.Draft

    timestamps(type: :utc_datetime)
  end

  def changeset(pick, attrs) do
    pick
    |> cast(attrs, [
      :draft_id,
      :pack_number,
      :pick_number,
      :picked_arena_id,
      :pack_arena_ids,
      :pool_arena_ids,
      :picked_at
    ])
    |> validate_required([:draft_id, :pack_number, :pick_number, :picked_arena_id])
    |> unique_constraint([:draft_id, :pack_number, :pick_number],
      name: :drafts_picks_draft_id_pack_number_pick_number_index
    )
  end
end
