defmodule Scry2.Events.Gameplay.StartingPlayerChosen do
  @moduledoc """
  Domain event — the player chose to play or draw after winning the die roll.

  ## Slug

  `"starting_player_chosen"` — stable, do not rename.

  ## Source

  Produced from `ClientToGremessage` raw events with type
  `ClientMessageType_ChooseStartingPlayerResp`. `chose_play` is true
  when the player chose to go first (play).
  """

  @enforce_keys [:occurred_at]
  defstruct [:player_id, :mtga_match_id, :chose_play, :occurred_at]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          chose_play: boolean() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "starting_player_chosen"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
