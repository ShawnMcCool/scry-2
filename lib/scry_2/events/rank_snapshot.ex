defmodule Scry2.Events.RankSnapshot do
  @moduledoc """
  Domain event — a point-in-time snapshot of the player's rank in
  constructed and limited formats. Fires after match results are
  processed by MTGA's servers.

  ## Slug

  `"rank_snapshot"` — stable, do not rename.

  ## Source

  Produced from `RankGetSeasonAndRankDetails` response events. These
  are Format A `<==` responses carrying the full rank state. Request
  events (with `"request": "{}"`) are skipped.
  """

  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :constructed_class,
    :constructed_level,
    :constructed_step,
    :constructed_matches_won,
    :constructed_matches_lost,
    :limited_class,
    :limited_level,
    :limited_step,
    :limited_matches_won,
    :limited_matches_lost,
    :season_ordinal,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          constructed_class: String.t() | nil,
          constructed_level: integer() | nil,
          constructed_step: integer() | nil,
          constructed_matches_won: integer() | nil,
          constructed_matches_lost: integer() | nil,
          limited_class: String.t() | nil,
          limited_level: integer() | nil,
          limited_step: integer() | nil,
          limited_matches_won: integer() | nil,
          limited_matches_lost: integer() | nil,
          season_ordinal: integer() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "rank_snapshot"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
