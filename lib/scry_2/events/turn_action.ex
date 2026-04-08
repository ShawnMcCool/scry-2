defmodule Scry2.Events.TurnAction do
  @moduledoc """
  Domain event — a discrete, meaningful action within a game turn.

  ## Slug

  `"turn_action"` — stable, do not rename.

  ## Source

  Produced by `IdentifyDomainEvents` from `GreToClientEvent` messages
  containing `GameStateMessage` with annotations. The translator
  groups related annotations into single meaningful actions.

  ## Action categories

  Derived from MTGA's `AnnotationType_ZoneTransfer` categories and
  other annotation combinations:

  - `"play_land"` — land played from hand to battlefield
  - `"cast_spell"` — spell cast from hand to stack
  - `"resolve"` — spell/ability resolved from stack
  - `"draw"` — card drawn from library to hand
  - `"destroy"` — permanent destroyed to graveyard
  - `"sacrifice"` — permanent sacrificed to graveyard
  - `"exile"` — card exiled
  - `"discard"` — card discarded from hand
  - `"return"` — card returned to hand/library
  - `"create_token"` — token created on battlefield
  - `"combat_damage"` — damage dealt in combat
  - `"life_change"` — life total modified (non-combat)
  - `"counter_added"` — counter placed on a permanent
  - `"attach"` — aura/equipment attached

  ## Enrichment (ADR-030)

  `card_name` and `card_arena_id` are stamped at ingestion from the
  cumulative game object state (ADR-025). The `turn_number`, `phase`,
  and `active_player` come from the GameStateMessage's `turnInfo`.
  """

  @enforce_keys [:action, :occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :action,
    :turn_number,
    :phase,
    :step,
    :active_player,
    :card_arena_id,
    :card_name,
    :affected_card_arena_id,
    :affected_card_name,
    :zone_from,
    :zone_to,
    :amount,
    :details,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          action: String.t(),
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          step: String.t() | nil,
          active_player: integer() | nil,
          card_arena_id: integer() | nil,
          card_name: String.t() | nil,
          affected_card_arena_id: integer() | nil,
          affected_card_name: String.t() | nil,
          zone_from: String.t() | nil,
          zone_to: String.t() | nil,
          amount: integer() | nil,
          details: map() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "turn_action"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
