defmodule Scry2.Events.Session.SessionStarted do
  @moduledoc """
  The player authenticated with MTGA. Carries the Wizards user ID needed for
  self-user-id auto-detection and the player's screen name.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `AuthenticateResponse` event. Fires when the MTGA client successfully
  authenticates with the back-end service at session start.

  ## Fields

  - `player_id` — MTGA player identifier (populated from `client_id` after enrichment)
  - `client_id` — Wizards user ID; matches `mtga_self_user_id` in config and enables
    auto-detection without manual configuration
  - `screen_name` — player's current MTGA display name
  - `session_id` — MTGA session token for this connection

  ## Slug

  `"session_started"` — stable, do not rename.
  """

  @enforce_keys [:client_id, :occurred_at]
  defstruct [
    :player_id,
    :client_id,
    :screen_name,
    :session_id,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          client_id: String.t(),
          screen_name: String.t() | nil,
          session_id: String.t() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "session_started"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
