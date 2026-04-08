defmodule Scry2.Events.Draft.HumanDraftPackOffered do
  @moduledoc """
  Domain event — a pack was presented to the player during a human draft
  (Premier Draft, Traditional Draft). Bot drafts use `DraftPickMade`
  instead, which combines pack + pick.

  ## Slug

  `"human_draft_pack_offered"` — stable, do not rename.

  ## Source

  Produced from `Draft.Notify` response events. The first pick of pack 1
  does NOT generate a `Draft.Notify` — the first event appears at pick 2.
  Filter out entries with a `"method"` key (those are RPC metadata, not packs).

  Pack contents arrive as a comma-separated string of arena_ids in `PackCards`.
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
