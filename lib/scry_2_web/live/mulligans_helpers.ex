defmodule Scry2Web.MulligansHelpers do
  @moduledoc """
  Pure functions for mulligan display — decision inference, grouping,
  and formatting. Extracted per ADR-013 for unit testing.

  Works with `%Scry2.Mulligans.MulliganListing{}` projection rows.
  """

  alias Scry2.Mulligans.MulliganListing

  @doc """
  Groups mulligan listing rows into a display hierarchy:

      [%{event_name: "Quick Draft — FDN", games: [%{hands: [{hand, :kept | :mulliganed}]}]}]

  Sort order per user spec:
    1. Events (sets): newest first (desc by first game timestamp)
    2. Games within event: oldest first (asc — chronological play order)
    3. Hands within game: oldest first (asc — mulligan sequence order)

  Each `hand` in the output is a map with `:arena_ids`, `:hand_size`,
  and `:occurred_at` — extracted from the listing row for template use.
  """
  def group_for_display(listings) when is_list(listings) do
    listings
    |> Enum.group_by(& &1.mtga_match_id)
    |> Enum.map(fn {match_id, rows} ->
      hands = annotate_decisions(rows)
      event_name = infer_event_name(rows)
      %{match_id: match_id, event_name: event_name, hands: hands}
    end)
    |> Enum.group_by(& &1.event_name)
    |> Enum.map(fn {event_name, games} ->
      sorted_games =
        games
        |> Enum.sort_by(
          fn %{hands: [{first, _} | _]} -> first.occurred_at end,
          {:asc, DateTime}
        )

      %{event_name: event_name, games: sorted_games}
    end)
    |> Enum.sort_by(
      fn %{games: games} ->
        games
        |> List.last()
        |> then(fn %{hands: [{last, _} | _]} -> last.occurred_at end)
      end,
      {:desc, DateTime}
    )
  end

  @doc """
  Given a list of mulligan listing rows for one game (one match_id),
  returns `[{hand_map, :kept | :mulliganed}]` sorted ascending by
  `occurred_at`.

  Decision is read from the `decision` field stamped by the projector
  at write time. Sort order is preserved for correct display sequence.
  """
  def annotate_decisions([]), do: []

  def annotate_decisions(rows) when is_list(rows) do
    rows
    |> Enum.sort_by(& &1.occurred_at, {:asc, DateTime})
    |> Enum.map(fn row ->
      decision = if row.decision == "kept", do: :kept, else: :mulliganed
      {to_hand(row), decision}
    end)
  end

  @doc "Returns a short label for the decision."
  def decision_label(:kept), do: "Keep"
  def decision_label(:mulliganed), do: "Mulligan"

  @doc "Returns a CSS class for the decision badge."
  def decision_badge_class(:kept), do: "bg-orange-500/90 text-white"
  def decision_badge_class(:mulliganed), do: "bg-blue-500/90 text-white"

  @doc "Delegates to `Scry2Web.CoreComponents.format_event_name/1`."
  defdelegate format_event_name(event_name), to: Scry2Web.CoreComponents

  # ── Internals ───────────────────────────────────────────────────────────

  defp to_hand(%MulliganListing{} = row) do
    %{
      arena_ids: (row.hand_arena_ids && row.hand_arena_ids["cards"]) || [],
      hand_size: row.hand_size,
      occurred_at: row.occurred_at,
      land_count: row.land_count,
      nonland_count: row.nonland_count,
      total_cmc: row.total_cmc,
      cmc_distribution: row.cmc_distribution || %{},
      color_distribution: row.color_distribution || %{}
    }
  end

  defp infer_event_name(rows) do
    rows
    |> Enum.find_value(fn row ->
      if row.event_name && row.event_name != "", do: format_event_name(row.event_name)
    end) || "Unknown Event"
  end
end
