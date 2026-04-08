defmodule Scry2.Events.IngestionState do
  @moduledoc """
  Typed, versioned, serializable ingestion state. Tracks the translation
  context as raw MTGA events are processed into domain events.

  ## Scopes

  - `session` — survives match boundaries (player identity, rank)
  - `match` — cleared on MatchCompleted (match ID, game number, deck)

  ## State transitions

  `apply_event/2` is a pure function: given current state + domain event,
  returns `{new_state, side_effect_events}`. Side effects are domain events
  deferred from earlier (e.g. DeckSubmitted from a ConnectResp that arrived
  before MatchCreated).

  ## Persistence

  Serialized to a singleton `ingestion_state` DB row after each raw event.
  On restart, loaded and resumed from `last_raw_event_id`.
  """

  alias __MODULE__.{Match, Session}

  @current_version 1

  @derive Jason.Encoder
  defstruct version: @current_version,
            last_raw_event_id: 0,
            session: %Session{},
            match: %Match{}

  @type t :: %__MODULE__{
          version: pos_integer(),
          last_raw_event_id: non_neg_integer(),
          session: Session.t(),
          match: Match.t()
        }

  @doc "Returns a fresh ingestion state, optionally seeded with a self_user_id."
  def new(opts \\ []) do
    self_user_id = Keyword.get(opts, :self_user_id)
    %__MODULE__{session: %Session{self_user_id: self_user_id}}
  end

  @doc "Advances the raw event cursor."
  def advance(%__MODULE__{} = state, raw_event_id) when is_integer(raw_event_id) do
    %{state | last_raw_event_id: raw_event_id}
  end

  # -- apply_event -----------------------------------------------------------

  @doc """
  Pure state transition. Returns `{new_state, side_effect_events}`.

  Side effects are domain events that were deferred and are now ready
  to emit (e.g. pending DeckSubmitted after MatchCreated arrives).
  """
  def apply_event(
        %__MODULE__{session: %Session{} = current_session} = state,
        %Scry2.Events.Session.SessionStarted{} = event
      ) do
    # Note: player_id is NOT set here — it's resolved by IngestRawEvents
    # via Players.find_or_create! and set on the session directly, because
    # the DB lookup is a side effect that doesn't belong in a pure function.
    session = %Session{
      current_session
      | self_user_id: event.client_id,
        current_session_id: event.session_id
    }

    {%{state | session: session}, []}
  end

  def apply_event(%__MODULE__{} = state, %Scry2.Events.Deck.DeckSelected{} = event) do
    {put_in(state.match.last_deck_name, event.deck_name), []}
  end

  def apply_event(%__MODULE__{} = state, %Scry2.Events.Match.MatchCreated{} = event) do
    new_state = put_in(state.match.current_match_id, event.mtga_match_id)

    case new_state.match.pending_deck do
      nil ->
        {new_state, []}

      deck ->
        completed_deck = %{
          deck
          | mtga_match_id: event.mtga_match_id,
            mtga_deck_id: "#{event.mtga_match_id}:seat1"
        }

        {put_in(new_state.match.pending_deck, nil), [completed_deck]}
    end
  end

  def apply_event(%__MODULE__{} = state, %Scry2.Events.Match.DieRolled{} = event) do
    {put_in(state.match.on_play_for_current_game, event.self_goes_first), []}
  end

  def apply_event(%__MODULE__{} = state, %Scry2.Events.Gameplay.StartingPlayerChosen{} = event) do
    {put_in(state.match.on_play_for_current_game, event.chose_play), []}
  end

  def apply_event(
        %__MODULE__{} = state,
        %Scry2.Events.Deck.DeckSubmitted{mtga_match_id: nil} = event
      ) do
    {put_in(state.match.pending_deck, event), []}
  end

  def apply_event(%__MODULE__{} = state, %Scry2.Events.Deck.DeckSubmitted{}) do
    current_game = (state.match.current_game_number || 0) + 1
    {put_in(state.match.current_game_number, current_game), []}
  end

  def apply_event(%__MODULE__{} = state, %Scry2.Events.Match.MatchCompleted{}) do
    {%{state | match: %Match{}}, []}
  end

  def apply_event(%__MODULE__{} = state, _event), do: {state, []}

  # -- Serialization ---------------------------------------------------------

  @doc "Deserializes a JSON map (from DB) into an IngestionState struct."
  def from_map(nil), do: new()

  def from_map(%{} = map) do
    session_map = map["session"] || %{}
    match_map = map["match"] || %{}

    %__MODULE__{
      version: map["version"] || @current_version,
      last_raw_event_id: map["last_raw_event_id"] || 0,
      session: %Session{
        self_user_id: session_map["self_user_id"],
        player_id: session_map["player_id"],
        current_session_id: session_map["current_session_id"],
        constructed_rank: session_map["constructed_rank"],
        limited_rank: session_map["limited_rank"]
      },
      match: %Match{
        current_match_id: match_map["current_match_id"],
        current_game_number: match_map["current_game_number"],
        last_deck_name: match_map["last_deck_name"],
        on_play_for_current_game: match_map["on_play_for_current_game"],
        pending_deck: match_map["pending_deck"],
        last_hand_game_objects: match_map["last_hand_game_objects"] || %{}
      }
    }
  end
end
