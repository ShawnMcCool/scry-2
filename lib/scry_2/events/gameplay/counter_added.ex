defmodule Scry2.Events.Gameplay.CounterAdded do
  @moduledoc """
  A counter was placed on a permanent during a game.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing an `AnnotationType_ObjectIdChanged` annotation for counter
  placement. Fires when any counter (e.g. +1/+1, loyalty, charge) is added
  to a permanent.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the counter was added in
  - `turn_number` — turn number when the counter was placed
  - `phase` — game phase during which the counter was placed
  - `active_player` — seat ID of the player whose turn it is
  - `card_arena_id` — arena_id of the permanent receiving the counter
  - `card_name` — resolved card name (enriched at ingestion)
  - `amount` — number of counters added

  ## Slug

  `"counter_added"` — stable, do not rename.
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
    def type_slug(_), do: "counter_added"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
