defmodule Scry2.Drafts.Draft do
  use Ecto.Schema
  import Ecto.Changeset

  schema "drafts_drafts" do
    field :player_id, :integer
    field :mtga_draft_id, :string
    field :event_name, :string
    field :format, :string
    field :set_code, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :deck_submitted_at, :utc_datetime
    field :mtga_deck_id, :string
    field :card_pool_arena_ids, :map

    # Virtual — populated by Scry2.Drafts read queries via JOIN+window over
    # matches_matches in [deck_submitted_at, next_deck_submitted_at). Never
    # persisted; nil when the query that loaded the draft didn't compute them.
    field :wins, :integer, virtual: true, default: nil
    field :losses, :integer, virtual: true, default: nil

    has_many :picks, Scry2.Drafts.Pick

    timestamps(type: :utc_datetime)
  end

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [
      :player_id,
      :mtga_draft_id,
      :event_name,
      :format,
      :set_code,
      :started_at,
      :completed_at,
      :deck_submitted_at,
      :mtga_deck_id,
      :card_pool_arena_ids
    ])
    |> validate_required([:mtga_draft_id])
    |> unique_constraint([:player_id, :mtga_draft_id])
  end
end
