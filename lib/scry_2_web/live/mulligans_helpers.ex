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

  Games are sorted oldest-first (chronological play order within an event).
  Hands within each game are sorted oldest-first (mulligan sequence order).
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
      {:asc, DateTime}
    )
  end

  @doc """
  Groups matches by event name, producing a two-level hierarchy:

      [%{event_name: "Quick Draft — FDN", games: [%{match_id: ..., hands: ...}, ...]}]

  `match_lookup` is a map of `%{mtga_match_id => %Match{}}` used to
  resolve event names. Matches without a lookup entry are grouped under
  "Unknown Event".

  Events are sorted newest-first. Games within each event are also
  newest-first.
  """
  def group_by_event(matches, match_lookup) do
    matches
    |> Enum.group_by(fn %{match_id: match_id} ->
      case Map.get(match_lookup, match_id) do
        %{event_name: name} when is_binary(name) and name != "" -> format_event_name(name)
        _ -> "Unknown Event"
      end
    end)
    |> Enum.map(fn {event_name, games} ->
      %{event_name: event_name, games: games}
    end)
    |> Enum.sort_by(
      fn %{games: [%{hands: [{first, _} | _]} | _]} -> first.occurred_at end,
      {:desc, DateTime}
    )
  end

  @doc """
  Formats an MTGA event name into a readable label.

  Examples:
      "QuickDraft_FDN_20260323" → "Quick Draft — FDN"
      "PremierDraft_LCI_20260401" → "Premier Draft — LCI"
      "CompDraft_BLB_20260501" → "Comp Draft — BLB"
      "Ladder" → "Ladder"
  """
  def format_event_name(event_name) when is_binary(event_name) do
    case String.split(event_name, "_") do
      [prefix, set_code | _] ->
        label =
          prefix
          |> String.replace("QuickDraft", "Quick Draft")
          |> String.replace("PremierDraft", "Premier Draft")
          |> String.replace("CompDraft", "Comp Draft")
          |> String.replace("TradDraft", "Traditional Draft")
          |> String.replace("BotDraft", "Bot Draft")

        "#{label} — #{set_code}"

      _ ->
        event_name
    end
  end

  @doc """
  Returns a short label for the decision.
  """
  @spec decision_label(:kept | :mulliganed) :: String.t()
  def decision_label(:kept), do: "Keep"
  def decision_label(:mulliganed), do: "Mulligan"

  @doc """
  Returns a CSS class for the decision badge.
  """
  @spec decision_badge_class(:kept | :mulliganed) :: String.t()
  def decision_badge_class(:kept), do: "bg-orange-500/90 text-white"
  def decision_badge_class(:mulliganed), do: "bg-blue-500/90 text-white"
end
