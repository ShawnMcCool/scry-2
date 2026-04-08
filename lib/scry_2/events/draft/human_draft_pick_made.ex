defmodule Scry2.Events.Draft.HumanDraftPickMade do
  @moduledoc """
  Domain event — the player selected a card during a human draft
  (Premier Draft, Traditional Draft). Unlike bot draft's `DraftPickMade`,
  human drafts separate the pack presentation (`HumanDraftPackOffered`)
  from the pick confirmation.

  ## Slug

  `"human_draft_pick_made"` — stable, do not rename.

  ## Source

  Produced from `EventPlayerDraftMakePick` response events. The `GrpIds`
  field is an array — some formats like Pick Two Draft allow selecting
  multiple cards per pick.
  """

  @enforce_keys [:mtga_draft_id, :pack_number, :pick_number, :picked_arena_ids, :occurred_at]
  defstruct [
    :player_id,
    :mtga_draft_id,
    :pack_number,
    :pick_number,
    :picked_arena_ids,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_draft_id: String.t(),
          pack_number: pos_integer(),
          pick_number: pos_integer(),
          picked_arena_ids: [integer()],
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "human_draft_pick_made"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
