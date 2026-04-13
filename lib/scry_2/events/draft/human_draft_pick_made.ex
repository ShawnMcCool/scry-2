defmodule Scry2.Events.Draft.HumanDraftPickMade do
  @moduledoc """
  The player confirmed a card selection during a human draft (Premier Draft,
  Traditional Draft). Unlike bot draft's `DraftPickMade`, human drafts separate
  the pack presentation (`HumanDraftPackOffered`) from the pick confirmation.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `EventPlayerDraftMakePick` response. Fires when the player confirms their
  selection and the server acknowledges it. The `GrpIds` field is an array —
  some formats like Pick Two Draft allow selecting multiple cards per pick.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_draft_id` — links this pick to a draft session
  - `pack_number` — which pack was picked from (1–3)
  - `pick_number` — position within the pack (1–15 for a normal pack)
  - `picked_arena_ids` — list of arena_ids selected (usually one, more for Pick Two)

  ## Slug

  `"human_draft_pick_made"` — stable, do not rename.
  """

  @enforce_keys [:mtga_draft_id, :pack_number, :pick_number, :picked_arena_ids, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

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

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_draft_id: payload["mtga_draft_id"],
      pack_number: payload["pack_number"],
      pick_number: payload["pick_number"],
      picked_arena_ids: payload["picked_arena_ids"] || [],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "human_draft_pick_made"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
