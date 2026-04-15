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

  alias __MODULE__.{Match, Session, Snapshot}
  alias Scry2.Repo

  @current_version 1

  # snapshot_state is intentionally excluded from DB persistence and resets to %{} on restart.
  # The first snapshot of each type after restart is always appended (no previous key to compare
  # against), which is safe and correct: it re-establishes the last-known baseline. Cross-restart
  # dedup would require loading the last-seen diff key per event type from the domain event log
  # on startup — complexity not worth the marginal benefit of skipping one extra append.
  @derive {Jason.Encoder, except: [:snapshot_state]}
  defstruct version: @current_version,
            last_raw_event_id: 0,
            session: %Session{},
            match: %Match{},
            snapshot_state: %{}

  @type t :: %__MODULE__{
          version: pos_integer(),
          last_raw_event_id: non_neg_integer(),
          session: Session.t(),
          match: Match.t(),
          snapshot_state: %{optional(String.t()) => term()}
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

  def apply_event(%__MODULE__{} = state, %Scry2.Events.Deck.DeckSubmitted{} = event) do
    current_game = (state.match.current_game_number || 0) + 1

    match =
      %{state.match | current_game_number: current_game}
      |> then(fn m ->
        # Capture the player's seat from the ConnectResp that produced this
        # DeckSubmitted. Persists across games so GameCompleted uses the
        # correct perspective even when ConnectResp was in a prior GRE batch.
        if event.self_seat_id, do: %{m | self_seat_id: event.self_seat_id}, else: m
      end)

    {%{state | match: match}, []}
  end

  def apply_event(%__MODULE__{} = state, %Scry2.Events.Match.MatchCompleted{}) do
    {%{state | match: %Match{}}, []}
  end

  def apply_event(%__MODULE__{} = state, %Scry2.Events.Turn.TurnStarted{turn_number: turn}) do
    new_tps = Map.merge(state.match.turn_phase_state, %{turn: turn, phase: nil, step: nil})
    {put_in(state.match.turn_phase_state, new_tps), []}
  end

  def apply_event(%__MODULE__{} = state, %Scry2.Events.Turn.PhaseChanged{phase: phase, step: step}) do
    new_tps = Map.merge(state.match.turn_phase_state, %{phase: phase, step: step})
    {put_in(state.match.turn_phase_state, new_tps), []}
  end

  def apply_event(%__MODULE__{} = state, _event), do: {state, []}

  # -- Diagnostics -----------------------------------------------------------

  @doc """
  Pure projection of the state into a friendly map for display in the
  diagnostics panel. Excludes verbose fields like
  `game_objects`, `turn_phase_state`, `game_object_states` and replaces `pending_deck` with a boolean
  `pending_deck?` so the UI stays readable.
  """
  @spec project(t()) :: map()
  def project(%__MODULE__{} = state) do
    %{
      last_raw_event_id: state.last_raw_event_id,
      session: %{
        self_user_id: state.session.self_user_id,
        player_id: state.session.player_id,
        current_session_id: state.session.current_session_id,
        constructed_rank: state.session.constructed_rank,
        limited_rank: state.session.limited_rank
      },
      match: %{
        current_match_id: state.match.current_match_id,
        current_game_number: state.match.current_game_number,
        last_deck_name: state.match.last_deck_name,
        on_play_for_current_game: state.match.on_play_for_current_game,
        pending_deck?: not is_nil(state.match.pending_deck)
      }
    }
  end

  # -- Persistence -----------------------------------------------------------

  @singleton_id 1

  @doc "Persists the current state to the database."
  def persist!(%__MODULE__{} = state) do
    attrs = %{
      version: state.version,
      last_raw_event_id: state.last_raw_event_id,
      session: Jason.decode!(Jason.encode!(state.session)),
      match:
        Jason.decode!(
          Jason.encode!(%{
            state.match
            | game_objects: %{},
              turn_phase_state: %{},
              game_object_states: %{},
              pending_deck: nil
          })
        )
    }

    case Repo.get(Snapshot, @singleton_id) do
      nil -> %Snapshot{id: @singleton_id}
      existing -> existing
    end
    |> Snapshot.changeset(attrs)
    |> Repo.insert_or_update!()

    state
  end

  @doc """
  Loads the persisted state from the database.
  Returns a fresh `%IngestionState{}` if no snapshot exists.
  """
  def load(opts \\ []) do
    case Repo.get(Snapshot, @singleton_id) do
      nil ->
        new(opts)

      snapshot ->
        from_map(%{
          "version" => snapshot.version,
          "last_raw_event_id" => snapshot.last_raw_event_id,
          "session" => snapshot.session,
          "match" => snapshot.match
        })
    end
  end

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
        game_objects: match_map["game_objects"] || %{}
      }
    }
  end
end
