defmodule Scry2.Events.Progression.RankSnapshot do
  @moduledoc """
  Point-in-time snapshot of the player's constructed and limited ranks,
  including class, level, step, win/loss record, and leaderboard position.

  Event type: :snapshot

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from `RankGetSeasonAndRankDetails`
  and `RankGetCombinedRankInfo` response events (Format A `<==` responses carrying
  the full rank state). Fires after each ranked match and on login. Request events
  (with `"request": "{}"`) are skipped.

  ## Fields

  - `player_id` — MTGA player identifier
  - `constructed_class` — constructed rank class (e.g. `"Gold"`, `"Mythic"`)
  - `constructed_level` — tier within the rank class (1–4 for non-mythic)
  - `constructed_step` — progress steps within the current tier
  - `constructed_matches_won` — constructed wins this season
  - `constructed_matches_lost` — constructed losses this season
  - `constructed_percentile` — mythic percentile ranking (nil if not mythic)
  - `constructed_leaderboard_placement` — leaderboard rank number (nil if not top placement)
  - `limited_class` — limited rank class (e.g. `"Gold"`, `"Mythic"`)
  - `limited_level` — tier within the rank class (1–4 for non-mythic)
  - `limited_step` — progress steps within the current tier
  - `limited_matches_won` — limited wins this season
  - `limited_matches_lost` — limited losses this season
  - `limited_percentile` — mythic percentile ranking (nil if not mythic)
  - `limited_leaderboard_placement` — leaderboard rank number (nil if not top placement)
  - `season_ordinal` — current ranked season number

  ## Diff key

  `SnapshotDiff` compares all class/level/step/wins/losses/season fields for
  both constructed and limited. `player_id` and `occurred_at` are excluded
  (metadata). Percentile and leaderboard placement are included as they reflect
  rank position changes within mythic.

  ## Slug

  `"rank_snapshot"` — stable, do not rename.
  """

  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :constructed_class,
    :constructed_level,
    :constructed_step,
    :constructed_matches_won,
    :constructed_matches_lost,
    :constructed_percentile,
    :constructed_leaderboard_placement,
    :limited_class,
    :limited_level,
    :limited_step,
    :limited_matches_won,
    :limited_matches_lost,
    :limited_percentile,
    :limited_leaderboard_placement,
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
          constructed_percentile: number() | nil,
          constructed_leaderboard_placement: integer() | nil,
          limited_class: String.t() | nil,
          limited_level: integer() | nil,
          limited_step: integer() | nil,
          limited_matches_won: integer() | nil,
          limited_matches_lost: integer() | nil,
          limited_percentile: number() | nil,
          limited_leaderboard_placement: integer() | nil,
          season_ordinal: integer() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "rank_snapshot"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
