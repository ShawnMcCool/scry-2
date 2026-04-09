defmodule Scry2.Events.Economy.InventoryUpdated do
  @moduledoc """
  Snapshot of the player's economy state — gold, gems, wildcards, vault progress,
  and draft/sealed tokens. Excludes booster counts (see `InventorySnapshot`).

  Event type: :snapshot

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from `StartHook` events (every
  login) and `EventClaimPrize` events (after claiming event rewards). Fires when
  the associated raw event carries `InventoryInfo` with the full economy totals.

  ## Fields

  - `player_id` — MTGA player identifier
  - `gold` — current gold balance
  - `gems` — current gem balance
  - `wildcards_common` — count of common wildcards available
  - `wildcards_uncommon` — count of uncommon wildcards available
  - `wildcards_rare` — count of rare wildcards available
  - `wildcards_mythic` — count of mythic rare wildcards available
  - `vault_progress` — vault completion percentage (0.0–100.0)
  - `draft_tokens` — draft tokens available for use
  - `sealed_tokens` — sealed tokens available for use

  ## Diff key

  `SnapshotDiff` compares all economy fields except boosters (boosters are
  tracked separately by `InventorySnapshot`). `player_id` and `occurred_at`
  are excluded (metadata).

  ## Slug

  `"inventory_updated"` — stable, do not rename.
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
    :draft_tokens,
    :sealed_tokens,
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
          draft_tokens: non_neg_integer() | nil,
          sealed_tokens: non_neg_integer() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "inventory_updated"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
