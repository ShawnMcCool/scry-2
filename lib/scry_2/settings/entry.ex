defmodule Scry2.Settings.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :key}
  schema "settings_entries" do
    field :value, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
  end
end
