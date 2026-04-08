defmodule Scry2.Events.IngestionState.Session do
  @moduledoc """
  Session-scoped ingestion state. Survives match boundaries.
  Reset on new SessionStarted.
  """

  @derive Jason.Encoder
  defstruct self_user_id: nil,
            player_id: nil,
            current_session_id: nil,
            constructed_rank: nil,
            limited_rank: nil

  @type t :: %__MODULE__{
          self_user_id: String.t() | nil,
          player_id: integer() | nil,
          current_session_id: String.t() | nil,
          constructed_rank: String.t() | nil,
          limited_rank: String.t() | nil
        }
end
