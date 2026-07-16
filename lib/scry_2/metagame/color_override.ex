defmodule Scry2.Metagame.ColorOverride do
  @moduledoc """
  Manual card-color assignment from MTGOFormatData's
  `color_overrides.json` — e.g. marking a five-color land as WUBRG for
  color detection. `land` distinguishes the Lands and NonLands override
  lists; `colors` is a WUBRG-ordered string.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "metagame_color_overrides" do
    field :format, :string
    field :card_name, :string
    field :land, :boolean
    field :colors, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required [:format, :card_name, :land, :colors]

  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(override \\ %__MODULE__{}, attrs) do
    override
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> unique_constraint([:format, :card_name, :land])
  end
end
