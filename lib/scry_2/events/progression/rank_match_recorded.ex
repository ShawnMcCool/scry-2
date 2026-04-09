defmodule Scry2.Events.Progression.RankMatchRecorded do
  @moduledoc """
  A ranked match result was recorded — wins or losses changed in a ranked format.

  Event type: :state_change

  ## Source

  Emitted alongside `RankAdvanced` by `SnapshotConvert` when a changed
  `RankSnapshot` shows a higher wins or losses count in either constructed or
  limited. One event per format whose record changed.

  ## Fields

  - `player_id` — MTGA player identifier
  - `format` — which ranked format this result is for (`:constructed` or `:limited`)
  - `won` — true if wins increased; false if losses increased; nil if ambiguous
  - `wins` — new total wins this season
  - `losses` — new total losses this season
  - `occurred_at` — when the result was observed

  ## Slug

  `"rank_match_recorded"` — stable, do not rename.
  """

  @enforce_keys [:format, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  defstruct [
    :player_id,
    :format,
    :won,
    :wins,
    :losses,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          format: :constructed | :limited,
          won: boolean() | nil,
          wins: integer() | nil,
          losses: integer() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      format: payload["format"] && String.to_existing_atom(payload["format"]),
      won: payload["won"],
      wins: payload["wins"],
      losses: payload["losses"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "rank_match_recorded"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
