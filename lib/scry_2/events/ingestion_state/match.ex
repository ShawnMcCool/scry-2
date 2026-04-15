defmodule Scry2.Events.IngestionState.Match do
  @moduledoc """
  Match-scoped ingestion state. Reset to a fresh struct on MatchCompleted.
  """

  @derive Jason.Encoder
  defstruct current_match_id: nil,
            current_game_number: nil,
            self_seat_id: nil,
            last_deck_name: nil,
            on_play_for_current_game: nil,
            pending_deck: nil,
            # Full accumulated instance_id → arena_id map across all GameStateMessages.
            # Supersedes last_hand_game_objects (removed).
            game_objects: %{},
            # Current turn/phase/step for delta detection. Avoids emitting duplicate
            # TurnStarted/PhaseChanged events when consecutive messages share the same state.
            turn_phase_state: %{},
            # Per-object state map for delta detection: instance_id → %{tapped, power, toughness}.
            game_object_states: %{}

  @type t :: %__MODULE__{
          current_match_id: String.t() | nil,
          current_game_number: non_neg_integer() | nil,
          self_seat_id: non_neg_integer() | nil,
          last_deck_name: String.t() | nil,
          on_play_for_current_game: boolean() | nil,
          pending_deck: map() | nil,
          game_objects: %{optional(integer()) => integer()},
          turn_phase_state: %{optional(atom()) => term()},
          game_object_states: %{optional(integer()) => map()}
        }
end
