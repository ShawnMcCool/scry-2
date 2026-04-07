defmodule Scry2Web.MulligansHelpers do
  @moduledoc """
  Pure functions for mulligan display — decision inference from event
  sequences and hand formatting. Extracted per ADR-013 for unit testing.
  """

  alias Scry2.Events.MulliganOffered

  @doc """
  Given a list of MulliganOffered events for one game (ordered by occurred_at),
  returns a list of `{event, :kept | :mulliganed}`.

  Under London mulligan rules, each successive offer has a smaller hand_size.
  The last offer in the sequence was the kept hand. All prior offers were mulliganed.

  If there's only one offer, it was kept (player kept their opening 7).
  """
  @spec annotate_decisions([MulliganOffered.t()]) :: [{MulliganOffered.t(), :kept | :mulliganed}]
  def annotate_decisions([]), do: []

  def annotate_decisions(offers) when is_list(offers) do
    sorted = Enum.sort_by(offers, & &1.occurred_at, DateTime)
    {all_but_last, [last]} = Enum.split(sorted, -1)

    mulliganed = Enum.map(all_but_last, fn offer -> {offer, :mulliganed} end)
    kept = [{last, :kept}]

    mulliganed ++ kept
  end

  @doc """
  Groups mulligan events by match, returning a list of
  `%{match_id: String.t(), hands: [{MulliganOffered.t(), :kept | :mulliganed}]}`.

  Each match's hands are ordered chronologically.
  """
  @spec group_by_match([MulliganOffered.t()]) :: [map()]
  def group_by_match(mulligan_events) do
    mulligan_events
    |> Enum.group_by(& &1.mtga_match_id)
    |> Enum.map(fn {match_id, events} ->
      %{match_id: match_id, hands: annotate_decisions(events)}
    end)
    |> Enum.sort_by(
      fn %{hands: [{first, _} | _]} -> first.occurred_at end,
      {:desc, DateTime}
    )
  end

  @doc """
  Returns a short label for the decision.
  """
  @spec decision_label(:kept | :mulliganed) :: String.t()
  def decision_label(:kept), do: "Kept"
  def decision_label(:mulliganed), do: "Mulliganed"

  @doc """
  Returns a CSS class for the decision badge.
  """
  @spec decision_badge_class(:kept | :mulliganed) :: String.t()
  def decision_badge_class(:kept), do: "badge-warning badge-outline"
  def decision_badge_class(:mulliganed), do: "badge-info badge-outline"

  @doc """
  Returns a CSS border class for the hand row accent.
  """
  @spec decision_border_class(:kept | :mulliganed) :: String.t()
  def decision_border_class(:kept), do: "border-warning"
  def decision_border_class(:mulliganed), do: "border-info"
end
