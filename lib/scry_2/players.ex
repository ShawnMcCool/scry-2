defmodule Scry2.Players do
  @moduledoc """
  Context module for MTGA player identity.

  Owns table: `players`.

  PubSub role: broadcasts `"players:updates"` after discovery or update.

  Players are auto-discovered from `SessionStarted` domain events during
  ingestion. The first time a new `client_id` appears, a player record is
  created. Screen names are updated on subsequent sessions.
  """

  import Ecto.Query

  alias Scry2.Players.Player
  alias Scry2.Repo
  alias Scry2.Topics

  @doc """
  Gets or creates a player by MTGA user ID.

  If the player exists, updates the screen_name if it changed.
  Returns the player record.
  """
  def get_or_create!(mtga_user_id, screen_name)
      when is_binary(mtga_user_id) and is_binary(screen_name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(Player, mtga_user_id: mtga_user_id) do
      nil ->
        player =
          %Player{}
          |> Player.changeset(%{
            mtga_user_id: mtga_user_id,
            screen_name: screen_name,
            first_seen_at: now
          })
          |> Repo.insert!()

        Topics.broadcast(Topics.players_updates(), {:player_discovered, player})
        player

      %Player{screen_name: ^screen_name} = player ->
        player

      %Player{} = player ->
        player =
          player
          |> Player.changeset(%{screen_name: screen_name})
          |> Repo.update!()

        Topics.broadcast(Topics.players_updates(), {:player_updated, player})
        player
    end
  end

  @doc "Returns all players, ordered by first_seen_at."
  def list_players do
    Player
    |> order_by([p], asc: p.first_seen_at)
    |> Repo.all()
  end

  @doc "Returns the player with the given id, or nil."
  def get_player(id) when is_integer(id) do
    Repo.get(Player, id)
  end

  @doc "Returns the player with the given MTGA user ID, or nil."
  def get_by_mtga_user_id(mtga_user_id) when is_binary(mtga_user_id) do
    Repo.get_by(Player, mtga_user_id: mtga_user_id)
  end

  @doc "Returns the total number of players."
  def count do
    Repo.aggregate(Player, :count)
  end
end
