defmodule Scry2.Events.Draft.DraftCompleted do
  @moduledoc """
  Domain event — the draft portion is finished and the full card pool
  is available. Applies to both human drafts (Premier, Traditional) and
  bot drafts (Quick Draft).

  ## Slug

  `"draft_completed"` — stable, do not rename.

  ## Source

  Produced from `DraftCompleteDraft` response events. The `CardPool` field
  carries the complete array of drafted arena_ids. `IsBotDraft` distinguishes
  Quick Draft from human draft pods.
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
