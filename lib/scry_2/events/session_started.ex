defmodule Scry2.Events.SessionStarted do
  @moduledoc """
  Domain event — the player authenticated with MTGA. Carries the
  `client_id` (Wizards user ID) needed for self-user-id auto-detection
  and the player's screen name.

  ## Slug

  `"session_started"` — stable, do not rename.

  ## Source

  Produced from `AuthenticateResponse` events. The `client_id` is the
  same value as `mtga_self_user_id` in config — capturing it here
  enables auto-detection without manual configuration.
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
