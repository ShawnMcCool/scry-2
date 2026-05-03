defmodule Scry2.Matches.RankFormat do
  @moduledoc """
  Compose human-readable rank strings from MTGA's class+tier pair.

  Used by the matches and decks contexts to produce values like
  `"Gold 3"` or `"Mythic"` from the raw class/tier fields surfaced
  by the log translator and the memory-observation enricher.

  **Mythic special case:** MTGA emits `tier: 1` for Mythic-tier players,
  but at Mythic the tier number has no meaning (the meaningful suffix
  is encoded in the placement / percentile fields, displayed
  separately by `Scry2Web.Components.RankBadge`). This module collapses
  any Mythic+tier input to just `"Mythic"`.

  **None special case:** `RankClass.name(0)` returns `"None"` — a
  sentinel meaning "the player has no rank to display". This module
  collapses any `"None"` input to `nil` so the UI hides the badge
  rather than rendering the literal word "None".
  """

  @spec compose(String.t() | nil, integer() | nil) :: String.t() | nil
  def compose(nil, _tier), do: nil
  def compose("None", _tier), do: nil
  def compose("Mythic", _tier), do: "Mythic"
  def compose(class, nil), do: class
  def compose(class, tier), do: "#{class} #{tier}"
end
