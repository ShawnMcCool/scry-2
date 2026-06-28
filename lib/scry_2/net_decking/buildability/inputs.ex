defmodule Scry2.NetDecking.Buildability.Inputs do
  @moduledoc """
  Typed input to the buildability engine. Assembled by the NetDecking
  context from `Cards` + `Collection`; the engine itself queries nothing.
  """
  @enforce_keys [:main_cards, :side_cards, :owned, :wildcards, :rarities, :free_arena_ids]
  defstruct [:main_cards, :side_cards, :owned, :wildcards, :rarities, :free_arena_ids]

  @type wildcard_map :: %{
          common: integer(),
          uncommon: integer(),
          rare: integer(),
          mythic: integer()
        }
  @type t :: %__MODULE__{
          main_cards: [%{arena_id: integer(), count: integer()}],
          side_cards: [%{arena_id: integer(), count: integer()}],
          owned: %{optional(integer()) => integer()},
          wildcards: wildcard_map(),
          rarities: %{optional(integer()) => String.t()},
          free_arena_ids: MapSet.t()
        }
end
