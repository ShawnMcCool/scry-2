defmodule Scry2.Events.Match.MatchCreated do
  @moduledoc """
  A new MTGA match was created and the lobby has handed control to the game
  room. This is the "match is about to begin" event.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `MatchGameRoomStateChangedEvent` with `stateType: "MatchGameRoomStateType_Playing"`.
  Fires when the match game room transitions to the playing state.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — stable match identifier; all subsequent match events share this
  - `event_name` — MTGA event this match is part of (e.g. `"Play_Ranked"`)
  - `opponent_screen_name` — opponent's display name
  - `opponent_user_id` — opponent's MTGA user ID
  - `platform` — player's platform (e.g. `"PC"`, `"Mac"`)
  - `opponent_platform` — opponent's platform
  - `opponent_rank_class` — opponent's rank class at match start (e.g. `"Gold"`)
  - `opponent_rank_tier` — opponent's rank tier within their class (1–4)
  - `opponent_leaderboard_percentile` — opponent's percentile for mythic ranked
  - `opponent_leaderboard_placement` — opponent's placement for mythic ranked
  - `player_rank` — player's rank string at match start (enriched at ingestion, ADR-030)
  - `format` — derived format name (enriched at ingestion)
  - `format_type` — derived format type (enriched at ingestion)
  - `deck_name` — deck name from the pending deck context (enriched at ingestion)

  ## Slug

  `"match_created"` — stable, do not rename.
  """

  @enforce_keys [:mtga_match_id, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  defstruct [
    :player_id,
    :mtga_match_id,
    :event_name,
    :opponent_screen_name,
    :opponent_user_id,
    :platform,
    :opponent_platform,
    :opponent_rank_class,
    :opponent_rank_tier,
    :opponent_leaderboard_percentile,
    :opponent_leaderboard_placement,
    :occurred_at,
    # Enriched at ingestion (ADR-030)
    :player_rank,
    :format,
    :format_type,
    :deck_name
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_match_id: String.t(),
          event_name: String.t() | nil,
          opponent_screen_name: String.t() | nil,
          opponent_user_id: String.t() | nil,
          platform: String.t() | nil,
          opponent_platform: String.t() | nil,
          opponent_rank_class: String.t() | nil,
          opponent_rank_tier: integer() | nil,
          opponent_leaderboard_percentile: number() | nil,
          opponent_leaderboard_placement: integer() | nil,
          occurred_at: DateTime.t(),
          player_rank: String.t() | nil,
          format: String.t() | nil,
          format_type: String.t() | nil,
          deck_name: String.t() | nil
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      event_name: payload["event_name"],
      opponent_screen_name: payload["opponent_screen_name"],
      opponent_user_id: payload["opponent_user_id"],
      platform: payload["platform"],
      opponent_platform: payload["opponent_platform"],
      opponent_rank_class: payload["opponent_rank_class"],
      opponent_rank_tier: payload["opponent_rank_tier"],
      opponent_leaderboard_percentile: payload["opponent_leaderboard_percentile"],
      opponent_leaderboard_placement: payload["opponent_leaderboard_placement"],
      player_rank: payload["player_rank"],
      format: payload["format"],
      format_type: payload["format_type"],
      deck_name: payload["deck_name"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "match_created"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
