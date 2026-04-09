defmodule Scry2.Events.Event.EventRewardClaimed do
  @moduledoc """
  The player claimed their rewards after completing an MTGA event. Carries
  the specific rewards granted and the final event win/loss record.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `EventClaimPrize`
  response. Fires when the player claims rewards at the end of an event run.
  Companion `InventoryChanged` events capture each individual currency delta
  from the same response.

  ## Fields

  - `player_id` — MTGA player identifier
  - `event_name` — internal MTGA event identifier for the completed event
  - `final_wins` — total wins accumulated before claiming
  - `final_losses` — total losses accumulated before claiming
  - `gems_awarded` — gems granted as part of the prize
  - `gold_awarded` — gold granted as part of the prize
  - `boosters_awarded` — list of booster pack awards (may be nil)
  - `card_pool` — complete card pool for the event run (draft/sealed only)

  ## Slug

  `"event_reward_claimed"` — stable, do not rename.
  """

  @enforce_keys [:event_name, :occurred_at]
  defstruct [
    :player_id,
    :event_name,
    :final_wins,
    :final_losses,
    :gems_awarded,
    :gold_awarded,
    :boosters_awarded,
    :card_pool,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          event_name: String.t(),
          final_wins: non_neg_integer() | nil,
          final_losses: non_neg_integer() | nil,
          gems_awarded: non_neg_integer() | nil,
          gold_awarded: non_neg_integer() | nil,
          boosters_awarded: [map()] | nil,
          card_pool: [integer()] | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "event_reward_claimed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
