defmodule Scry2.Events.Gameplay.StartingPlayerChosen do
  @moduledoc """
  The player chose to play or draw after winning the die roll.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `ClientToGremessage`
  with type `ClientMessageType_ChooseStartingPlayerResp`. Fires when the player
  who won the die roll submits their play/draw choice.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match this choice was made in
  - `chose_play` — true if the player chose to go first (play), false for draw

  ## Slug

  `"starting_player_chosen"` — stable, do not rename.
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
