defmodule Scry2.Events.IngestionState.Match do
  @moduledoc """
  Match-scoped ingestion state. Reset to a fresh struct on MatchCompleted.
  """

  @derive Jason.Encoder
  defstruct current_match_id: nil,
            current_game_number: nil,
            last_deck_name: nil,
            on_play_for_current_game: nil,
            pending_deck: nil,
            last_hand_game_objects: %{}

  @type t :: %__MODULE__{
          current_match_id: String.t() | nil,
          current_game_number: non_neg_integer() | nil,
          last_deck_name: String.t() | nil,
          on_play_for_current_game: boolean() | nil,
          pending_deck: map() | nil,
          last_hand_game_objects: map()
        }
end
