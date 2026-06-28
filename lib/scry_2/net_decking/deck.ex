defmodule Scry2.NetDecking.Deck do
  @moduledoc """
  A single external reference deck in the NetDecking corpus.

  Card lists (`main_deck`, `sideboard`) use the same `{"cards" => [%{arena_id, count}]}`
  shape as `decks_decks`. `composition_hash` enables idempotent re-ingest.
  `unresolved_cards` records references that did not map to an arena_id —
  the deck is still stored; the UI flags it as incompletely resolved.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "netdecking_decks" do
    field :name, :string
    field :archetype, :string
    field :format, :string, default: "Standard"
    field :main_deck, :map
    field :sideboard, :map
    field :composition_hash, :integer
    field :source_name, :string
    field :source_url, :string
    field :fetched_at, :utc_datetime_usec
    field :unresolved_cards, :map

    timestamps(type: :utc_datetime_usec)
  end

  @required [:name, :format, :main_deck, :sideboard, :source_name, :fetched_at]
  @optional [:archetype, :composition_hash, :source_url, :unresolved_cards]

  @spec changeset(map()) :: Ecto.Changeset.t()
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(deck \\ %__MODULE__{}, attrs) do
    deck
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end
end
