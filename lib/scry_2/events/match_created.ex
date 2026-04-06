defmodule Scry2.Events.MatchCreated do
  @moduledoc """
  Domain event — a new MTGA match was created and the lobby has handed
  control to the game room. This is the "match is about to begin" event.

  ## Slug

  `"match_created"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `MatchGameRoomStateChangedEvent` with `stateType: "MatchGameRoomStateType_Playing"`.

  ## Projected by

  `Scry2.MatchListing.UpdateFromEvent` — creates a row in `matches_matches` via
  `Scry2.MatchListing.upsert_match!/1`.

  ## Real-time consumers

  Any LiveView or analytics tool that wants to react to "user started a
  match" subscribes to `Scry2.Topics.domain_events/0` and matches on this
  struct.
  """

  @enforce_keys [:mtga_match_id, :occurred_at]
  defstruct [
    :mtga_match_id,
    :event_name,
    :opponent_screen_name,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          mtga_match_id: String.t(),
          event_name: String.t() | nil,
          opponent_screen_name: String.t() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "match_created"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
