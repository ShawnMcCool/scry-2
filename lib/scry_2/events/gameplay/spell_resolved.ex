defmodule Scry2.Events.Gameplay.SpellResolved do
  @moduledoc """
  A spell or ability resolved from the stack.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing an `AnnotationType_ZoneTransfer` annotation with category
  `Resolve`. Fires when a spell or ability leaves the stack after resolving.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the spell resolved in
  - `turn_number` — turn number when the spell resolved
  - `phase` — game phase when the spell resolved
  - `active_player` — seat ID of the player whose turn it is
  - `card_arena_id` — arena_id of the spell or ability that resolved
  - `card_name` — resolved card name (enriched at ingestion)

  ## Slug

  `"spell_resolved"` — stable, do not rename.
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
    def type_slug(_), do: "spell_resolved"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
