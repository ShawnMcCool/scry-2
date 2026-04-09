defmodule Scry2.Events.Gameplay.PermanentDestroyed do
  @moduledoc """
  A permanent was destroyed and moved to its owner's graveyard.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing an `AnnotationType_ZoneTransfer` annotation transitioning a
  permanent to the graveyard via destruction (not sacrifice, which produces
  `ZoneChanged` instead). Fires when a destroy effect resolves.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the destruction occurred in
  - `turn_number` — turn number when the permanent was destroyed
  - `phase` — game phase during which the destruction occurred
  - `active_player` — seat ID of the player whose turn it is
  - `card_arena_id` — arena_id of the destroyed permanent
  - `card_name` — resolved card name (enriched at ingestion)

  ## Slug

  `"permanent_destroyed"` — stable, do not rename.
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
    def type_slug(_), do: "permanent_destroyed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
