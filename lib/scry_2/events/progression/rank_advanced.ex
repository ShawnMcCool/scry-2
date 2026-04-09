defmodule Scry2.Events.Progression.RankAdvanced do
  @moduledoc """
  The player's rank changed — class, level, step, wins, losses, or leaderboard
  position shifted in either constructed or limited.

  Event type: :state_change

  ## Source

  Produced by `SnapshotConvert` from a changed `RankSnapshot`. Fires whenever
  any rank-related field differs between the previous and current snapshot.
  Carries the complete rank state at the moment of change, making it the
  projection source for rank history.

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
  - `occurred_at` — when the rank change was observed

  ## Slug

  `"rank_advanced"` — stable, do not rename.
  """

  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

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

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      constructed_class: payload["constructed_class"],
      constructed_level: payload["constructed_level"],
      constructed_step: payload["constructed_step"],
      constructed_matches_won: payload["constructed_matches_won"],
      constructed_matches_lost: payload["constructed_matches_lost"],
      constructed_percentile: payload["constructed_percentile"],
      constructed_leaderboard_placement: payload["constructed_leaderboard_placement"],
      limited_class: payload["limited_class"],
      limited_level: payload["limited_level"],
      limited_step: payload["limited_step"],
      limited_matches_won: payload["limited_matches_won"],
      limited_matches_lost: payload["limited_matches_lost"],
      limited_percentile: payload["limited_percentile"],
      limited_leaderboard_placement: payload["limited_leaderboard_placement"],
      season_ordinal: payload["season_ordinal"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "rank_advanced"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
