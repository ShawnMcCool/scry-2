defmodule Scry2.Mulligans do
  @moduledoc """
  Context module for mulligan data — read-optimized projections
  for the mulligans page.

  Owns table: `mulligans_mulligan_listing`.

  PubSub role: broadcasts `"mulligans:updates"` after projection writes.

  This context exists per ADR-026 (page-specific projections). The
  mulligans page queries this context directly rather than assembling
  data from the event log and matches table at render time.
  """

  import Ecto.Query

  alias Scry2.Mulligans.MulliganListing
  alias Scry2.Repo

  @doc """
  Lists all mulligan hands for the given player, ordered by
  `occurred_at` descending (newest first).
  """
  def list_hands(opts \\ []) do
    MulliganListing
    |> maybe_filter_by_player(opts[:player_id])
    |> order_by([m], desc: m.occurred_at)
    |> Repo.all()
  end

  defp maybe_filter_by_player(query, nil), do: query
  defp maybe_filter_by_player(query, player_id), do: where(query, [m], m.player_id == ^player_id)

  @doc """
  Upserts a mulligan listing row by `(mtga_match_id, occurred_at)`.
  """
  def upsert_hand!(attrs) do
    attrs = Map.new(attrs)

    %MulliganListing{}
    |> MulliganListing.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:mtga_match_id, :occurred_at]
    )
  end

  @doc """
  Stamps `event_name` on all mulligan rows for a given match.
  Called when `MatchCreated` is projected (which carries the event name).
  """
  def stamp_event_name!(mtga_match_id, event_name)
      when is_binary(mtga_match_id) and is_binary(event_name) do
    from(m in MulliganListing, where: m.mtga_match_id == ^mtga_match_id)
    |> Repo.update_all(set: [event_name: event_name])
  end

  @doc """
  Marks all existing hands for a match as `"mulliganed"`.
  Called just before inserting a new hand offer — the prior hand was
  definitively rejected under London mulligan rules.
  """
  def stamp_decision_mulliganed!(mtga_match_id) when is_binary(mtga_match_id) do
    from(m in MulliganListing, where: m.mtga_match_id == ^mtga_match_id)
    |> Repo.update_all(set: [decision: "mulliganed"])
  end

  @doc """
  Stamps `match_won` on all mulligan rows for a match.
  Called when `MatchCompleted` is projected.
  """
  def stamp_match_won!(mtga_match_id, won)
      when is_binary(mtga_match_id) and is_boolean(won) do
    from(m in MulliganListing, where: m.mtga_match_id == ^mtga_match_id)
    |> Repo.update_all(set: [match_won: won])
  end

  @doc """
  Returns mulligan analytics: keep rate by hand size and win rate by
  kept hand land count. Uses precomputed `decision` and `match_won`
  columns — no Elixir aggregation, no cross-context lookup.

  Returns:
    * `:by_hand_size` — keep rate per hand size (7, 6, 5, etc.)
    * `:by_land_count` — win rate when keeping a hand with N lands
    * `:total_hands` — total mulligan offers
    * `:total_keeps` — hands kept
  """
  def mulligan_analytics(opts \\ []) do
    player_id = opts[:player_id]

    total_hands =
      MulliganListing
      |> maybe_filter_by_player(player_id)
      |> Repo.aggregate(:count)

    total_keeps =
      MulliganListing
      |> maybe_filter_by_player(player_id)
      |> where([m], m.decision == "kept")
      |> Repo.aggregate(:count)

    by_hand_size =
      MulliganListing
      |> maybe_filter_by_player(player_id)
      |> where([m], not is_nil(m.decision))
      |> group_by([m], m.hand_size)
      |> select([m], %{
        hand_size: m.hand_size,
        total: count(),
        keeps: sum(fragment("CASE WHEN ? = 'kept' THEN 1 ELSE 0 END", m.decision))
      })
      |> order_by([m], desc: m.hand_size)
      |> Repo.all()
      |> Enum.map(fn row -> Map.put(row, :keep_rate, pct(row.keeps, row.total)) end)

    by_land_count =
      MulliganListing
      |> maybe_filter_by_player(player_id)
      |> where(
        [m],
        m.decision == "kept" and not is_nil(m.land_count) and not is_nil(m.match_won)
      )
      |> group_by([m], m.land_count)
      |> select([m], %{
        land_count: m.land_count,
        total: count(),
        wins: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", m.match_won))
      })
      |> order_by([m], asc: m.land_count)
      |> Repo.all()
      |> Enum.map(fn row -> Map.put(row, :win_rate, pct(row.wins, row.total)) end)

    %{
      total_hands: total_hands,
      total_keeps: total_keeps,
      by_hand_size: by_hand_size,
      by_land_count: by_land_count
    }
  end

  defp pct(_n, 0), do: nil
  defp pct(n, total), do: Float.round(n / total * 100, 1)
end
