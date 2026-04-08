defmodule Scry2.Events.InventoryUpdated do
  @moduledoc """
  Domain event — snapshot of the player's economy and collection state.

  ## Slug

  `"inventory_updated"` — stable, do not rename.

  ## Source

  Produced from `StartHook` raw events, which fire on every MTGA login.
  The `InventoryInfo` section carries gold, gems, wildcards, and vault
  progress. Tracking these over time reveals economy trends.

  Also produced from `EventClaimPrize` events which update inventory
  after claiming event rewards.
  """

  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :gold,
    :gems,
    :wildcards_common,
    :wildcards_uncommon,
    :wildcards_rare,
    :wildcards_mythic,
    :vault_progress,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          gold: non_neg_integer() | nil,
          gems: non_neg_integer() | nil,
          wildcards_common: non_neg_integer() | nil,
          wildcards_uncommon: non_neg_integer() | nil,
          wildcards_rare: non_neg_integer() | nil,
          wildcards_mythic: non_neg_integer() | nil,
          vault_progress: number() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "inventory_updated"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
