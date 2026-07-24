defmodule Scry2.NetDecking.Buildability.Inputs do
  @moduledoc """
  Typed input to the buildability engine. Assembled by the NetDecking
  context from `Cards` + `Collection`; the engine itself queries nothing.

  `unresolved_count` is the number of maindeck references that never
  resolved to an arena_id (cards not in the local MTGA database) — no
  wildcard count can fix those, so it gates `:incomplete` ahead of the
  cost/shortfall math rather than being folded into it.
  """
  @enforce_keys [
    :main_cards,
    :side_cards,
    :owned,
    :wildcards,
    :rarities,
    :free_arena_ids,
    :unresolved_count
  ]
  defstruct [
    :main_cards,
    :side_cards,
    :owned,
    :wildcards,
    :rarities,
    :free_arena_ids,
    :unresolved_count
  ]

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
          free_arena_ids: MapSet.t(),
          unresolved_count: non_neg_integer()
        }
end
