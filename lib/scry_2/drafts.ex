defmodule Scry2.Drafts do
  @moduledoc """
  Context module for draft sessions and individual card picks.

  Owns tables: `drafts_drafts`, `drafts_picks`.

  PubSub role:
    * subscribes to `"mtga_logs:events"` (via `Scry2.Drafts.Ingester`)
    * broadcasts `"drafts:updates"` after any mutation

  Picks reference cards by `arena_id` value, not via a belongs_to — see
  ADR-014 for the cross-context identity invariant.
  """

  import Ecto.Query

  alias Scry2.Drafts.{Draft, Pick}
  alias Scry2.Repo
  alias Scry2.Topics

  @doc "Returns drafts, newest first. Options: :limit, :player_id, :format, :set_code."
  def list_drafts(opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 50)
    player_id = Keyword.get(opts, :player_id)
    format = Keyword.get(opts, :format)
    set_code = Keyword.get(opts, :set_code)

    Draft
    |> maybe_filter_by_player(player_id)
    |> maybe_filter_by_format(format)
    |> maybe_filter_by_set(set_code)
    |> order_by([d], desc: d.started_at)
    |> limit(^limit_count)
    |> Repo.all()
  end

  @doc """
  Returns aggregate stats for drafts belonging to `player_id`.

  Keys: `:total`, `:win_rate` (float or nil), `:avg_wins` (float or nil),
  `:trophies` (count of 7-win drafts), `:by_format` (list of
  `%{format: string, total: int, win_rate: float}`).

  Only complete drafts (completed_at not nil) contribute to rates and averages.
  """
  def draft_stats(opts \\ []) do
    player_id = Keyword.get(opts, :player_id)

    base =
      Draft
      |> maybe_filter_by_player(player_id)

    total = Repo.aggregate(base, :count)

    complete_base = where(base, [d], not is_nil(d.completed_at))

    agg =
      complete_base
      |> select([d], %{
        total_wins: sum(d.wins),
        total_losses: sum(d.losses),
        trophies: fragment("COUNT(CASE WHEN ? = 7 THEN 1 END)", d.wins)
      })
      |> Repo.one()

    total_wins = agg.total_wins || 0
    total_losses = agg.total_losses || 0
    trophies = agg.trophies || 0

    win_rate =
      if total_wins + total_losses > 0,
        do: total_wins / (total_wins + total_losses),
        else: nil

    complete_count = Repo.aggregate(complete_base, :count)

    avg_wins =
      if complete_count > 0,
        do: total_wins / complete_count,
        else: nil

    by_format =
      complete_base
      |> group_by([d], d.format)
      |> select([d], %{
        format: d.format,
        total: count(d.id),
        total_wins: sum(d.wins),
        total_losses: sum(d.losses)
      })
      |> Repo.all()
      |> Enum.map(fn row ->
        w = row.total_wins || 0
        l = row.total_losses || 0
        rate = if w + l > 0, do: w / (w + l), else: nil
        Map.merge(row, %{win_rate: rate})
      end)
      |> Enum.sort_by(& &1.total, :desc)

    %{
      total: total,
      win_rate: win_rate,
      avg_wins: avg_wins,
      trophies: trophies,
      by_format: by_format
    }
  end

  @doc "Returns the draft with its picks preloaded, ordered by pack/pick."
  def get_draft_with_picks(id) do
    picks_query =
      from p in Pick, order_by: [asc: p.pack_number, asc: p.pick_number]

    Draft
    |> Repo.get(id)
    |> Repo.preload(picks: picks_query)
  end

  @doc "Returns the draft with the given MTGA id and optional player_id, or nil."
  def get_by_mtga_id(mtga_draft_id, player_id \\ nil) when is_binary(mtga_draft_id) do
    Draft
    |> where([d], d.mtga_draft_id == ^mtga_draft_id)
    |> maybe_filter_by_player(player_id)
    |> Repo.one()
  end

  @doc "Returns the draft with the given event_name and optional player_id, or nil."
  def get_by_event_name(event_name, player_id \\ nil) when is_binary(event_name) do
    Draft
    |> where([d], d.event_name == ^event_name)
    |> maybe_filter_by_player(player_id)
    |> Repo.one()
  end

  @doc """
  Upserts a draft session by `(player_id, mtga_draft_id)`. Idempotent per ADR-016.
  """
  def upsert_draft!(attrs) do
    attrs = Map.new(attrs)
    mtga_id = attrs[:mtga_draft_id] || attrs["mtga_draft_id"]
    player_id = attrs[:player_id] || attrs["player_id"]

    draft =
      case get_by_mtga_id(mtga_id, player_id) do
        nil -> %Draft{}
        existing -> existing
      end
      |> Draft.changeset(attrs)
      |> Repo.insert_or_update!()

    broadcast_update(draft.id)
    draft
  end

  @doc """
  Upserts a pick by `(draft_id, pack_number, pick_number)`. Idempotent.
  """
  def upsert_pick!(attrs) do
    attrs = Map.new(attrs)

    pick =
      case find_pick(attrs) do
        nil -> %Pick{}
        existing -> existing
      end
      |> Pick.changeset(attrs)
      |> Repo.insert_or_update!()

    broadcast_update(pick.draft_id)
    pick
  end

  defp find_pick(%{draft_id: draft_id, pack_number: p, pick_number: n}) do
    Repo.get_by(Pick, draft_id: draft_id, pack_number: p, pick_number: n)
  end

  @doc "Returns the total number of recorded drafts. Optionally filtered by player_id."
  def count(opts \\ []) do
    player_id = Keyword.get(opts, :player_id)

    Draft
    |> maybe_filter_by_player(player_id)
    |> Repo.aggregate(:count)
  end

  defp maybe_filter_by_player(query, nil), do: query
  defp maybe_filter_by_player(query, player_id), do: where(query, [d], d.player_id == ^player_id)

  defp maybe_filter_by_format(query, nil), do: query
  defp maybe_filter_by_format(query, format), do: where(query, [d], d.format == ^format)

  defp maybe_filter_by_set(query, nil), do: query
  defp maybe_filter_by_set(query, set_code), do: where(query, [d], d.set_code == ^set_code)

  defp broadcast_update(draft_id) do
    Topics.broadcast(Topics.drafts_updates(), {:draft_updated, draft_id})
  end
end
