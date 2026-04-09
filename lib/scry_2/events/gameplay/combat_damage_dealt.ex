defmodule Scry2.Events.Gameplay.CombatDamageDealt do
  @moduledoc """
  A creature dealt combat damage during the combat damage step.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing an `AnnotationType_DamageDealt` annotation during the combat
  damage step. Fires once per damage assignment.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the combat occurred in
  - `turn_number` — turn number when damage was dealt
  - `phase` — game phase (should be combat damage step)
  - `active_player` — seat ID of the attacking player
  - `card_arena_id` — arena_id of the creature dealing damage
  - `card_name` — resolved card name (enriched at ingestion)
  - `amount` — points of combat damage dealt

  ## Slug

  `"combat_damage_dealt"` — stable, do not rename.
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
    :amount,
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
          amount: integer() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "combat_damage_dealt"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
