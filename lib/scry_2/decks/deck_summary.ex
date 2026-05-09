defmodule Scry2.Decks.DeckSummary do
  @moduledoc """
  One row of the `Scry2.Decks.list_decks_with_stats/2` result: a deck plus
  aggregated BO1 and BO3 stats. Replaces the older
  `{deck, bo1_map, bo3_map}` triple — see ADR-013 (typed contracts at
  context boundaries).
  """

  alias Scry2.Decks.FormatStats

  @enforce_keys [:deck, :bo1, :bo3]
  defstruct [:deck, :bo1, :bo3]

  @type t :: %__MODULE__{
          deck: struct(),
          bo1: FormatStats.t(),
          bo3: FormatStats.t()
        }
end
