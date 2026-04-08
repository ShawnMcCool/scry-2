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
    |> maybe_filter_player(opts[:player_id])
    |> order_by([m], desc: m.occurred_at)
    |> Repo.all()
  end

  defp maybe_filter_player(query, nil), do: query
  defp maybe_filter_player(query, player_id), do: where(query, [m], m.player_id == ^player_id)

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
  Returns mulligan analytics: keep rate by hand size and win rate by
  kept hand land count. Joins mulligan hands to match outcomes.

  Returns:
    * `:by_hand_size` — keep rate per hand size (7, 6, 5, etc.)
    * `:by_land_count` — win rate when keeping a hand with N lands
    * `:total_hands` — total mulligan offers
    * `:total_keeps` — hands kept (inferred: last per match)
  """
  def mulligan_analytics(opts \\ []) do
    player_id = opts[:player_id]
    hands = list_hands(player_id: player_id)
    by_match = Enum.group_by(hands, & &1.mtga_match_id)

    # For each match, the last hand (by occurred_at) is the kept hand
    kept_hands =
      by_match
      |> Enum.map(fn {_match_id, match_hands} ->
        Enum.max_by(match_hands, & &1.occurred_at, DateTime)
      end)

    # Load match outcomes for the kept hands
    match_ids = Enum.map(kept_hands, & &1.mtga_match_id) |> Enum.uniq()
    outcomes = match_outcomes(match_ids)

    # Keep rate by hand size
    by_hand_size =
      by_match
      |> Enum.flat_map(fn {_match_id, match_hands} ->
        sorted = Enum.sort_by(match_hands, & &1.occurred_at, {:asc, DateTime})
        {mulliganed, [kept]} = Enum.split(sorted, -1)
        [{kept.hand_size, :kept} | Enum.map(mulliganed, &{&1.hand_size, :mulliganed})]
      end)
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {size, entries} ->
        total = length(entries)
        keeps = Enum.count(entries, fn {_, decision} -> decision == :kept end)
        %{hand_size: size, total: total, keeps: keeps, keep_rate: pct(keeps, total)}
      end)
      |> Enum.sort_by(& &1.hand_size, :desc)

    # Win rate by land count in kept hand
    by_land_count =
      kept_hands
      |> Enum.filter(&(&1.land_count != nil))
      |> Enum.group_by(& &1.land_count)
      |> Enum.map(fn {lands, hands_at_count} ->
        total = length(hands_at_count)
        wins = Enum.count(hands_at_count, fn hand -> outcomes[hand.mtga_match_id] == true end)
        %{land_count: lands, total: total, wins: wins, win_rate: pct(wins, total)}
      end)
      |> Enum.sort_by(& &1.land_count)

    %{
      total_hands: length(hands),
      total_keeps: length(kept_hands),
      by_hand_size: by_hand_size,
      by_land_count: by_land_count
    }
  end

  defp match_outcomes(match_ids) when match_ids == [], do: %{}

  defp match_outcomes(match_ids) do
    from(m in Scry2.Matches.Match,
      where: m.mtga_match_id in ^match_ids,
      select: {m.mtga_match_id, m.won}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp pct(_n, 0), do: nil
  defp pct(n, total), do: Float.round(n / total * 100, 1)
end
