defmodule Scry2.Cards.Set do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cards_sets" do
    field :code, :string
    field :name, :string
    field :released_at, :date

    has_many :cards, Scry2.Cards.Card, foreign_key: :set_id

    timestamps(type: :utc_datetime)
  end

  def changeset(set, attrs) do
    set
    |> cast(attrs, [:code, :name, :released_at])
    |> validate_required([:code, :name])
    |> unique_constraint(:code)
  end
end
