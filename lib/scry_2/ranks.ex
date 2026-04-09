defmodule Scry2.Ranks do
  @moduledoc """
  Context module for player rank progression.

  Owns table: `ranks_snapshots`.

  PubSub role: broadcasts `"ranks:updates"` after projection writes.
  """

  import Ecto.Query

  alias Scry2.Ranks.Snapshot
  alias Scry2.Repo
  alias Scry2.Topics

  @doc """
  Lists rank snapshots ordered by occurred_at ascending (oldest first),
  suitable for time-series display.
  """
  def list_snapshots(opts \\ []) do
    Snapshot
    |> maybe_filter_by_player(opts[:player_id])
    |> order_by([s], asc: s.occurred_at)
    |> Repo.all()
  end

  @doc "Returns the most recent snapshot, or nil."
  def latest_snapshot(opts \\ []) do
    Snapshot
    |> maybe_filter_by_player(opts[:player_id])
    |> order_by([s], desc: s.occurred_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Returns the total number of rank snapshots."
  def count(opts \\ []) do
    Snapshot
    |> maybe_filter_by_player(opts[:player_id])
    |> Repo.aggregate(:count)
  end

  @doc "Inserts a rank snapshot row."
  def insert_snapshot!(attrs) do
    snapshot =
      %Snapshot{}
      |> Snapshot.changeset(Map.new(attrs))
      |> Repo.insert!()

    Topics.broadcast(Topics.ranks_updates(), {:rank_updated, snapshot.id})
    snapshot
  end

  defp maybe_filter_by_player(query, nil), do: query
  defp maybe_filter_by_player(query, player_id), do: where(query, [s], s.player_id == ^player_id)
end
