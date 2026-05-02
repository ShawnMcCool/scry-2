defmodule Scry2.Matches.RankFormat do
  @moduledoc """
  Compose human-readable rank strings from MTGA's class+tier pair.

  Used by the matches and decks contexts to produce values like
  `"Gold 3"` or `"Mythic"` from the raw class/tier fields surfaced
  by the log translator and the memory-observation enricher.
  """

  @spec compose(String.t() | nil, integer() | nil) :: String.t() | nil
  def compose(nil, _tier), do: nil
  def compose(class, nil), do: class
  def compose(class, tier), do: "#{class} #{tier}"
end
