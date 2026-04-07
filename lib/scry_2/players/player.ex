defmodule Scry2.Players.Player do
  use Ecto.Schema
  import Ecto.Changeset

  schema "players" do
    field :mtga_user_id, :string
    field :screen_name, :string
    field :first_seen_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(player, attrs) do
    player
    |> cast(attrs, [:mtga_user_id, :screen_name, :first_seen_at])
    |> validate_required([:mtga_user_id, :screen_name, :first_seen_at])
    |> unique_constraint(:mtga_user_id)
  end
end
