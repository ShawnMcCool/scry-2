defmodule Scry2.Events.EventRewardClaimed do
  @moduledoc """
  Domain event — rewards claimed from completing an MTGA event.

  ## Slug

  `"event_reward_claimed"` — stable, do not rename.

  ## Source

  Produced from `EventClaimPrize` raw events. Carries the specific
  rewards granted (gems, gold, boosters, cards) and the final event
  record (wins, losses, card pool).
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
