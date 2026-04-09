defmodule Scry2.Events.Draft.DraftStarted do
  @moduledoc """
  A new MTGA bot draft session began. Marks the opening of a Quick Draft
  session before any picks are made.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `BotDraftDraftStatus`
  request. Fires when MTGA begins a bot draft session and the first status
  message arrives indicating the draft is underway.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_draft_id` — stable identifier for this draft session; links all picks
  - `event_name` — internal MTGA event name (e.g. `"QuickDraft_BLB_20250101"`)
  - `set_code` — three-letter set code being drafted (e.g. `"BLB"`)

  ## Slug

  `"draft_started"` — stable, do not rename.
  """

  @enforce_keys [:mtga_draft_id, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  defstruct [
    :player_id,
    :mtga_draft_id,
    :event_name,
    :set_code,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_draft_id: String.t(),
          event_name: String.t() | nil,
          set_code: String.t() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_draft_id: payload["mtga_draft_id"],
      event_name: payload["event_name"],
      set_code: payload["set_code"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "draft_started"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
