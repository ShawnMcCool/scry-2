defmodule Scry2.Events.Draft.HumanDraftPackOffered do
  @moduledoc """
  MTGA presented a pack to the player during a human draft (Premier Draft,
  Traditional Draft). Bot drafts use `DraftPickMade` instead, which bundles
  pack and pick into a single event.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `Draft.Notify`
  response. Fires each time MTGA presents a pack for the player to pick from.
  Note: the first pick of pack 1 does NOT generate a `Draft.Notify` — the
  first event appears at pick 2. Entries with a `"method"` key are RPC
  metadata and are filtered out. Pack contents arrive as a comma-separated
  string of arena_ids in `PackCards`.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_draft_id` — links this pack offer to a draft session
  - `pack_number` — which pack is being drafted (1–3)
  - `pick_number` — position within the pack (1–15 for a normal pack)
  - `pack_arena_ids` — list of arena_ids available for selection

  ## Slug

  `"human_draft_pack_offered"` — stable, do not rename.
  """

  @enforce_keys [:mtga_draft_id, :pack_number, :pick_number, :pack_arena_ids, :occurred_at]
  defstruct [
    :player_id,
    :mtga_draft_id,
    :pack_number,
    :pick_number,
    :pack_arena_ids,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_draft_id: String.t(),
          pack_number: pos_integer(),
          pick_number: pos_integer(),
          pack_arena_ids: [integer()],
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "human_draft_pack_offered"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
