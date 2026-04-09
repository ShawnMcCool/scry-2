defmodule Scry2.Events.Economy.InventoryChanged do
  @moduledoc """
  A discrete inventory transaction — entry fee paid or prize received.
  One event per change entry in an `EventJoin` or `EventClaimPrize` response.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from `EventJoin` and
  `EventClaimPrize` responses. Fires for each entry in `InventoryInfo.Changes[]`.
  The balance fields capture the resulting totals reported by the server after
  the change.

  ## Fields

  - `player_id` — MTGA player identifier
  - `source` — transaction source identifier (e.g. `"EventJoin"`, `"EventClaimPrize"`)
  - `source_id` — event or course ID associated with the transaction
  - `gold_delta` — gold added (positive) or spent (negative); nil if no gold change
  - `gems_delta` — gems added (positive) or spent (negative); nil if no gem change
  - `boosters` — list of `%{set_code, count}` booster packs awarded; nil if none
  - `gold_balance` — gold total after this transaction
  - `gems_balance` — gem total after this transaction

  ## Slug

  `"inventory_changed"` — stable, do not rename.
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
