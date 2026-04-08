defmodule Scry2.Events.Economy.InventoryChanged do
  @moduledoc """
  Domain event — the player's inventory changed due to a currency
  transaction (event entry fee, prize payout, etc.).

  ## Slug

  `"inventory_changed"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from `EventJoin`
  and `EventClaimPrize` responses. Each entry in
  `InventoryInfo.Changes[]` becomes one `InventoryChanged` event.
  The balance fields capture the resulting totals reported by the
  server after the change.
  """

  @enforce_keys [:source, :occurred_at]
  defstruct [
    :player_id,
    :source,
    :source_id,
    :gold_delta,
    :gems_delta,
    :boosters,
    :gold_balance,
    :gems_balance,
    :occurred_at
  ]

  @type booster :: %{set_code: String.t(), count: pos_integer()}

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          source: String.t(),
          source_id: String.t() | nil,
          gold_delta: integer() | nil,
          gems_delta: integer() | nil,
          boosters: [booster()] | nil,
          gold_balance: integer() | nil,
          gems_balance: integer() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "inventory_changed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
