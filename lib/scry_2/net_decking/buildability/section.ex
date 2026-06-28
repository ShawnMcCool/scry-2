defmodule Scry2.NetDecking.Buildability.Section do
  @moduledoc "Buildability result for one section (maindeck or sideboard)."
  @enforce_keys [:wildcard_cost, :shortfall, :owned_pct, :total_copies, :missing_copies]
  defstruct [:wildcard_cost, :shortfall, :owned_pct, :total_copies, :missing_copies]

  @type rarity_map :: %{
          common: integer(),
          uncommon: integer(),
          rare: integer(),
          mythic: integer()
        }
  @type t :: %__MODULE__{
          wildcard_cost: rarity_map(),
          shortfall: rarity_map(),
          owned_pct: float(),
          total_copies: integer(),
          missing_copies: integer()
        }
end
