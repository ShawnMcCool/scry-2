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
    field :wins, :integer
    field :losses, :integer

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
      :wins,
      :losses
    ])
    |> validate_required([:mtga_draft_id])
    |> unique_constraint([:player_id, :mtga_draft_id])
  end
end
