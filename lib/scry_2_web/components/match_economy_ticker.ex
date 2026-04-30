defmodule Scry2Web.Components.MatchEconomyTicker do
  @moduledoc """
  Compact "your last N matches" economy summary card. Used on the
  matches dashboard. Sums deltas across the visible matches and shows
  a one-line summary per currency.

  Logic-bearing helper `totals/1` is exposed for unit testing.
  """

  use Phoenix.Component

  attr :summaries, :list, required: true

  def ticker(assigns) do
    assigns = assign(assigns, :totals, totals(assigns.summaries))

    ~H"""
    <div class="card bg-base-200 shadow-sm" data-test="match-economy-ticker">
      <div class="card-body p-4">
        <h3 class="card-title text-sm uppercase tracking-wide opacity-70">
          Last {length(@summaries)} matches
        </h3>

        <div :if={@summaries == []} class="text-sm opacity-70">
          No match-economy data yet.
        </div>

        <div
          :if={@summaries != []}
          class="flex flex-wrap gap-3 text-sm"
        >
          <div>Gold: <span class="font-mono">{format(@totals.gold)}</span></div>
          <div>Gems: <span class="font-mono">{format(@totals.gems)}</span></div>
          <div>WC: <span class="font-mono">{format(@totals.wildcards_total)}</span> pips</div>
        </div>
      </div>
    </div>
    """
  end

  @doc false
  def totals(summaries) do
    Enum.reduce(
      summaries,
      %{gold: 0, gems: 0, wildcards_total: 0},
      fn s, acc ->
        %{
          gold: acc.gold + (s.memory_gold_delta || 0),
          gems: acc.gems + (s.memory_gems_delta || 0),
          wildcards_total:
            acc.wildcards_total +
              (s.memory_wildcards_common_delta || 0) +
              (s.memory_wildcards_uncommon_delta || 0) +
              (s.memory_wildcards_rare_delta || 0) +
              (s.memory_wildcards_mythic_delta || 0)
        }
      end
    )
  end

  defp format(0), do: "—"
  defp format(n) when is_integer(n) and n > 0, do: "+#{n}"
  defp format(n) when is_integer(n), do: "#{n}"
end
