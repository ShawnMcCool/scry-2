defmodule Scry2.Events.Gameplay.LandPlayed do
  @moduledoc """
  A land was played from hand to the battlefield.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing an `AnnotationType_ZoneTransfer` annotation with category
  `PlayLand`. Fires once per land drop — does not fire for lands entering
  via other means (e.g. put-into-play effects, which produce `ZoneChanged`).

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the land play occurred in
  - `turn_number` — turn number when the land was played
  - `phase` — game phase (should be main phase)
  - `active_player` — seat ID of the player playing the land
  - `card_arena_id` — arena_id of the land played
  - `card_name` — resolved card name (enriched at ingestion)

  ## Slug

  `"land_played"` — stable, do not rename.
  """

  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :turn_number,
    :phase,
    :active_player,
    :card_arena_id,
    :card_name,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          active_player: integer() | nil,
          card_arena_id: integer() | nil,
          card_name: String.t() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "land_played"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
