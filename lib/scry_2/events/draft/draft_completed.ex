defmodule Scry2.Events.Draft.DraftCompleted do
  @moduledoc """
  The draft portion of an event finished and the complete card pool is available.
  Applies to both human drafts (Premier, Traditional) and bot drafts (Quick Draft).

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `DraftCompleteDraft`
  response. Fires when the player has finished making all picks and the draft
  transitions to deck building. The `CardPool` field carries the complete array
  of drafted arena_ids. `IsBotDraft` distinguishes Quick Draft from human draft pods.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_draft_id` — MTGA draft identifier that links to individual picks
  - `event_name` — internal MTGA event name (e.g. `"QuickDraft_BLB_20250101"`)
  - `is_bot_draft` — true for Quick Draft (bot opponents), false for human pod drafts
  - `card_pool_arena_ids` — complete list of arena_ids for all cards drafted

  ## Slug

  `"draft_completed"` — stable, do not rename.
  """

  @enforce_keys [:mtga_draft_id, :occurred_at]
  defstruct [
    :player_id,
    :mtga_draft_id,
    :event_name,
    :is_bot_draft,
    :card_pool_arena_ids,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_draft_id: String.t(),
          event_name: String.t() | nil,
          is_bot_draft: boolean() | nil,
          card_pool_arena_ids: [integer()] | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "draft_completed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
