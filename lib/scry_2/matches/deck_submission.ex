defmodule Scry2.Matches.DeckSubmission do
  use Ecto.Schema
  import Ecto.Changeset

  schema "matches_deck_submissions" do
    field :mtga_deck_id, :string
    field :name, :string
    # List of %{"arena_id" => integer, "count" => integer} entries.
    # Cards are referenced by arena_id (not FK) — cross-context per ADR-014.
    field :main_deck, :map
    field :sideboard, :map, default: %{}
    field :submitted_at, :utc_datetime

    belongs_to :match, Scry2.Matches.Match

    timestamps(type: :utc_datetime)
  end

  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [:match_id, :mtga_deck_id, :name, :main_deck, :sideboard, :submitted_at])
    |> validate_required([:mtga_deck_id, :main_deck])
    |> unique_constraint(:mtga_deck_id)
  end
end
