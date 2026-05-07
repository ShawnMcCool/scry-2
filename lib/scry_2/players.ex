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

  @doc """
  Stamps `mtga_display_name` (the screen-name-with-discriminator form
  read from MTGA memory, e.g. `"Shawn McCool#91813"`) onto the player
  whose log-derived `screen_name` matches the bare-name prefix.

  Returns `{:ok, player}` on update, `{:ok, player}` when the value is
  already current (idempotent), or `:no_match` when no player has the
  bare-name prefix or the input is malformed / empty / nil.

  Broadcasts `{:player_updated, player}` only when the value actually
  changed — quiet when nothing moved so the polling caller doesn't
  spam subscribers.
  """
  @spec update_display_name_by_screen_name_prefix(String.t() | nil) ::
          {:ok, Player.t()} | :no_match
  def update_display_name_by_screen_name_prefix(display_name)
      when is_binary(display_name) and display_name != "" do
    case String.split(display_name, "#", parts: 2) do
      [prefix, _disc] when prefix != "" ->
        case Repo.get_by(Player, screen_name: prefix) do
          nil ->
            :no_match

          %Player{mtga_display_name: ^display_name} = player ->
            {:ok, player}

          %Player{} = player ->
            updated =
              player
              |> Player.changeset(%{mtga_display_name: display_name})
              |> Repo.update!()

            Topics.broadcast(Topics.players_updates(), {:player_updated, updated})
            {:ok, updated}
        end

      _ ->
        :no_match
    end
  end

  def update_display_name_by_screen_name_prefix(_), do: :no_match
end
