defmodule Scry2.Events.Economy.InventorySnapshot do
  @moduledoc """
  Domain event — standalone inventory state pushed by MTGA outside of
  event join/claim contexts. Captures the full economy state including
  tokens and boosters.

  ## Slug

  `"inventory_snapshot"` — stable, do not rename.

  ## Source

  Produced from `DTO_InventoryInfo` events, which MTGA pushes on
  inventory changes outside of event join/claim flows.
  """

  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :gold,
    :gems,
    :vault_progress,
    :wildcards_common,
    :wildcards_uncommon,
    :wildcards_rare,
    :wildcards_mythic,
    :draft_tokens,
    :sealed_tokens,
    :boosters,
    :occurred_at
  ]

  @type booster :: %{set_code: String.t(), count: non_neg_integer()}

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          gold: non_neg_integer() | nil,
          gems: non_neg_integer() | nil,
          vault_progress: number() | nil,
          wildcards_common: non_neg_integer() | nil,
          wildcards_uncommon: non_neg_integer() | nil,
          wildcards_rare: non_neg_integer() | nil,
          wildcards_mythic: non_neg_integer() | nil,
          draft_tokens: non_neg_integer() | nil,
          sealed_tokens: non_neg_integer() | nil,
          boosters: [booster()] | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "inventory_snapshot"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
