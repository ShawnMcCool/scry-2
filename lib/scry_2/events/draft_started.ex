defmodule Scry2.Events.DraftStarted do
  @moduledoc """
  Domain event — a new MTGA draft session began.

  ## Slug

  `"draft_started"` — stable, do not rename.

  ## Source (future)

  Will be produced by `Scry2.Events.Translator` once real draft fixtures
  exist. The user's current Player.log has no draft activity — run a
  draft with detailed logs enabled to collect fixtures. See
  `TODO.md` > "Match ingestion follow-ups" > Drafts.

  ## Projected by (future)

  `Scry2.Drafts.Projector` will project to `drafts_drafts` via
  `Scry2.Drafts.upsert_draft!/1`, keyed on `mtga_draft_id`.

  ## Status

  Struct defined; no translator clause, no projector handler, no fixtures.
  """

  @enforce_keys [:mtga_draft_id, :started_at]
  defstruct [
    :mtga_draft_id,
    :event_name,
    :set_code,
    :started_at
  ]

  @type t :: %__MODULE__{
          mtga_draft_id: String.t(),
          event_name: String.t() | nil,
          set_code: String.t() | nil,
          started_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "draft_started"
    def mtga_timestamp(%{started_at: ts}), do: ts
  end
end
