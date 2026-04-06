defmodule Scry2.Events.DraftPickMade do
  @moduledoc """
  Domain event — the user made a pick during a draft. Carries the pack
  contents at the moment of the pick, so replaying the entire draft is
  possible from the event log alone.

  ## Slug

  `"draft_pick_made"` — stable, do not rename.

  ## Source (future)

  Will be produced by `Scry2.Events.IdentifyDomainEvents` once real draft fixtures
  exist. See `TODO.md` > "Match ingestion follow-ups" > Drafts.

  ## Projected by (future)

  `Scry2.DraftListing.UpdateFromEvent` will project to `drafts_picks` via
  `Scry2.DraftListing.upsert_pick!/1`, keyed on `(draft_id, pack_number, pick_number)`.

  ## Status

  Struct defined; no translator clause, no projector handler, no fixtures.
  """

  @enforce_keys [:mtga_draft_id, :pack_number, :pick_number, :picked_arena_id, :occurred_at]
  defstruct [
    :mtga_draft_id,
    :pack_number,
    :pick_number,
    :picked_arena_id,
    :pack_arena_ids,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          mtga_draft_id: String.t(),
          pack_number: pos_integer(),
          pick_number: pos_integer(),
          picked_arena_id: integer(),
          pack_arena_ids: [integer()],
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "draft_pick_made"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
