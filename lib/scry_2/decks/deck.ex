defmodule Scry2.Decks.Deck do
  use Ecto.Schema
  import Ecto.Changeset

  schema "decks_decks" do
    field :mtga_deck_id, :string
    field :current_name, :string
    field :current_main_deck, :map, default: %{}
    field :current_sideboard, :map, default: %{}
    field :format, :string
    field :deck_colors, :string, default: ""
    field :first_seen_at, :utc_datetime
    field :last_played_at, :utc_datetime
    field :last_updated_at, :utc_datetime
    field :bo1_wins, :integer, default: 0
    field :bo1_losses, :integer, default: 0
    field :bo3_wins, :integer, default: 0
    field :bo3_losses, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(deck, attrs) do
    deck
    |> cast(attrs, [
      :mtga_deck_id,
      :current_name,
      :current_main_deck,
      :current_sideboard,
      :format,
      :deck_colors,
      :first_seen_at,
      :last_played_at,
      :last_updated_at,
      :bo1_wins,
      :bo1_losses,
      :bo3_wins,
      :bo3_losses
    ])
    |> validate_required([:mtga_deck_id])
    |> unique_constraint(:mtga_deck_id)
  end
end
