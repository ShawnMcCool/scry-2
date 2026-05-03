defmodule Scry2Web.Components.RankBadge do
  @moduledoc """
  Renders an MTGA rank string with optional Mythic-tier suffix.

  Sole place in the codebase that knows how to display a Mythic rank
  with placement (`Mythic #142`) or percentile (`Mythic 88%`).

  Inputs:
    * `:rank` — pre-composed string (e.g. `"Diamond 3"`, `"Mythic"`).
      Compose via `Scry2.Matches.RankFormat.compose/2` from the
      raw class+tier pair.
    * `:mythic_placement` — leaderboard placement when applicable.
      Treated as absent when nil or non-positive.
    * `:mythic_percentile` — percentile (0–100) when applicable.
      Treated as absent when nil or non-positive.

  Both Mythic fields treat `0` as "no value" because the live
  walker emits `0` for unset, while the DB columns use `nil` —
  this component handles both transparently.

  When both placement and percentile are positive, placement wins.
  """

  use Phoenix.Component

  attr :rank, :string, default: nil
  attr :mythic_placement, :integer, default: nil
  attr :mythic_percentile, :integer, default: nil
  attr :class, :string, default: ""

  def rank_badge(assigns) do
    ~H"""
    <span class={["badge badge-soft text-xs uppercase tracking-wide", @class]}>
      {display_text(assigns)}
    </span>
    """
  end

  @doc """
  Determine the display text for a rank badge given the rank string and
  optional Mythic-tier suffix integers. Returns "Unranked" for nil rank,
  "Mythic #N" when placement > 0, "Mythic N%" when percentile > 0, or
  the bare rank string otherwise.

  Public for unit testing per ADR-013.
  """
  @spec display_text(map()) :: String.t()
  def display_text(%{rank: nil}), do: "Unranked"

  def display_text(%{rank: "Mythic", mythic_placement: placement})
      when is_integer(placement) and placement > 0 do
    "Mythic ##{placement}"
  end

  def display_text(%{rank: "Mythic", mythic_percentile: percentile})
      when is_integer(percentile) and percentile > 0 do
    "Mythic #{percentile}%"
  end

  def display_text(%{rank: rank}), do: rank
end
