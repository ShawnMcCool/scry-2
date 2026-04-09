defmodule Scry2.Events.Draft.DraftPickMade do
  @moduledoc """
  The player made a pick during a bot draft (Quick Draft). Carries the pack
  contents at the moment of the pick, enabling full replay of the draft from
  the event log alone. Human drafts produce `HumanDraftPackOffered` +
  `HumanDraftPickMade` pairs instead.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `BotDraftDraftPick`
  request. Fires each time the player selects a card from a pack during a
  Quick Draft session.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_draft_id` — MTGA draft identifier linking picks to a `DraftStarted` event
  - `pack_number` — which pack is being drafted (1–3)
  - `pick_number` — position within the pack (1–15 for a normal pack)
  - `picked_arena_id` — arena_id of the card selected
  - `pack_arena_ids` — full list of arena_ids available in the pack before picking
  - `auto_pick` — true if MTGA auto-picked due to timeout
  - `time_remaining` — seconds remaining on the pick timer when the pick was made

  ## Slug

  `"draft_pick_made"` — stable, do not rename.
  """

  @enforce_keys [:mtga_draft_id, :pack_number, :pick_number, :picked_arena_id, :occurred_at]
  defstruct [
    :player_id,
    :mtga_draft_id,
    :pack_number,
    :pick_number,
    :picked_arena_id,
    :pack_arena_ids,
    :auto_pick,
    :time_remaining,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_draft_id: String.t(),
          pack_number: pos_integer(),
          pick_number: pos_integer(),
          picked_arena_id: integer(),
          pack_arena_ids: [integer()],
          auto_pick: boolean() | nil,
          time_remaining: number() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "draft_pick_made"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
