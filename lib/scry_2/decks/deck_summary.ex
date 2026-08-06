defmodule Scry2.Decks.DeckSummary do
  @moduledoc """
  One row of the `Scry2.Decks.list_decks_with_stats/2` result: a deck plus
  aggregated BO1 and BO3 stats and the card identities the group plays.
  Replaces the older `{deck, bo1_map, bo3_map}` triple — see ADR-013 (typed
  contracts at context boundaries).

  `card_names` is the `Scry2.DeckList.name_keys/2` set over the represented
  deck's maindeck AND sideboard — the same card-identity rule the netdeck
  catalog searches by. Cards with no `cards_cards` row are absent from it.
  """

  alias Scry2.Decks.FormatStats

  @enforce_keys [:deck, :bo1, :bo3, :card_names]
  defstruct [:deck, :bo1, :bo3, :card_names]

  @type t :: %__MODULE__{
          deck: struct(),
          bo1: FormatStats.t(),
          bo3: FormatStats.t(),
          card_names: MapSet.t(String.t())
        }
end
