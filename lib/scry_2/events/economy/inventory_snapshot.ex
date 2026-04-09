defmodule Scry2.Events.Economy.InventorySnapshot do
  @moduledoc """
  Full inventory state pushed by MTGA outside of event join/claim flows.
  Captures the complete economy state including tokens and boosters.

  Event type: :snapshot

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from `DTO_InventoryInfo`
  events. Fires when MTGA pushes an inventory update outside of the standard
  event join/claim flows (e.g. after opening a pack, crafting a card, or
  receiving a daily reward).

  ## Fields

  - `player_id` — MTGA player identifier
  - `gold` — current gold balance
  - `gems` — current gem balance
  - `vault_progress` — vault completion percentage (0.0–100.0)
  - `wildcards_common` — count of common wildcards available
  - `wildcards_uncommon` — count of uncommon wildcards available
  - `wildcards_rare` — count of rare wildcards available
  - `wildcards_mythic` — count of mythic rare wildcards available
  - `draft_tokens` — draft tokens available for use
  - `sealed_tokens` — sealed tokens available for use
  - `boosters` — list of `%{set_code, count}` for each set's booster count

  ## Diff key

  `SnapshotDiff` compares all economy fields including `boosters`. Any change
  in gold, gems, wildcards, tokens, or booster counts triggers a new event.
  `player_id` and `occurred_at` are excluded (metadata).

  ## Slug

  `"inventory_snapshot"` — stable, do not rename.
  """

  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

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

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      gold: payload["gold"],
      gems: payload["gems"],
      vault_progress: payload["vault_progress"],
      wildcards_common: payload["wildcards_common"],
      wildcards_uncommon: payload["wildcards_uncommon"],
      wildcards_rare: payload["wildcards_rare"],
      wildcards_mythic: payload["wildcards_mythic"],
      draft_tokens: payload["draft_tokens"],
      sealed_tokens: payload["sealed_tokens"],
      boosters: payload["boosters"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "inventory_snapshot"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
