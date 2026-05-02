defmodule Scry2.Crafts.Attribution do
  @moduledoc """
  Result of attributing a wildcard spend to a specific card.

  Produced by `Scry2.Crafts.AttributeCrafts.attribute/2` over a pair of
  consecutive `Scry2.Collection.Snapshot` rows. Plain typed struct —
  no DB, no persistence concerns. The Crafts facade turns these into
  `Scry2.Crafts.Craft` rows.

  See ADR-037 for the attribution rule.
  """

  @enforce_keys [:arena_id, :rarity, :quantity]
  defstruct [:arena_id, :rarity, :quantity]

  @type rarity :: :common | :uncommon | :rare | :mythic

  @type t :: %__MODULE__{
          arena_id: integer(),
          rarity: rarity(),
          quantity: pos_integer()
        }
end
