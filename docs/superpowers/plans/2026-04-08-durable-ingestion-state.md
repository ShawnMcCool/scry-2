# Durable Ingestion State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the volatile in-memory ingestion state with a typed struct persisted to SQLite after each raw event, enabling instant resume on restart.

**Architecture:** Extract state from IngestRawEvents GenServer into `IngestionState` struct with `Session` and `Match` sub-structs. Pure `apply_event/2` functions handle transitions, returning `{new_state, side_effects}`. State is snapshot-persisted to a singleton DB row after each raw event. On startup, load snapshot and catch up from `last_raw_event_id`.

**Tech Stack:** Elixir structs, Ecto/SQLite, Jason serialization

**Spec:** `docs/superpowers/specs/2026-04-08-durable-ingestion-state-design.md`

---

### Task 1: Create the IngestionState structs

**Files:**
- Create: `lib/scry_2/events/ingestion_state.ex`
- Create: `lib/scry_2/events/ingestion_state/session.ex`
- Create: `lib/scry_2/events/ingestion_state/match.ex`
- Test: `test/scry_2/events/ingestion_state_test.exs`

- [ ] **Step 1: Write the Match sub-struct**

Create `lib/scry_2/events/ingestion_state/match.ex`:

```elixir
defmodule Scry2.Events.IngestionState.Match do
  @moduledoc """
  Match-scoped ingestion state. Reset to a fresh struct on MatchCompleted.
  """

  @derive Jason.Encoder
  defstruct [
    current_match_id: nil,
    current_game_number: nil,
    last_deck_name: nil,
    on_play_for_current_game: nil,
    pending_deck: nil,
    last_hand_game_objects: %{}
  ]

  @type t :: %__MODULE__{
          current_match_id: String.t() | nil,
          current_game_number: non_neg_integer() | nil,
          last_deck_name: String.t() | nil,
          on_play_for_current_game: boolean() | nil,
          pending_deck: map() | nil,
          last_hand_game_objects: map()
        }
end
```

- [ ] **Step 2: Write the Session sub-struct**

Create `lib/scry_2/events/ingestion_state/session.ex`:

```elixir
defmodule Scry2.Events.IngestionState.Session do
  @moduledoc """
  Session-scoped ingestion state. Survives match boundaries.
  Reset on new SessionStarted.
  """

  @derive Jason.Encoder
  defstruct [
    self_user_id: nil,
    player_id: nil,
    current_session_id: nil,
    constructed_rank: nil,
    limited_rank: nil
  ]

  @type t :: %__MODULE__{
          self_user_id: String.t() | nil,
          player_id: integer() | nil,
          current_session_id: String.t() | nil,
          constructed_rank: String.t() | nil,
          limited_rank: String.t() | nil
        }
end
```

- [ ] **Step 3: Write the top-level IngestionState struct with apply_event**

Create `lib/scry_2/events/ingestion_state.ex`. This is the largest file — it holds the struct, `apply_event/2` clauses, serialization, and `new/0`.

```elixir
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
  defstruct [
    version: @current_version,
    last_raw_event_id: 0,
    session: %Session{},
    match: %Match{}
  ]

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

  # ── apply_event ──────────────────────────────────────────────────────

  @doc """
  Pure state transition. Returns `{new_state, side_effect_events}`.

  Side effects are domain events that were deferred and are now ready
  to emit (e.g. pending DeckSubmitted after MatchCreated arrives).
  """
  def apply_event(%__MODULE__{} = state, %Scry2.Events.Session.SessionStarted{} = event) do
    # Note: player_id is NOT set here — it's resolved by IngestRawEvents
    # via Players.find_or_create! and set on the session directly, because
    # the DB lookup is a side effect that doesn't belong in a pure function.
    session = %Session{
      state.session
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

  def apply_event(%__MODULE__{} = state, %Scry2.Events.Deck.DeckSubmitted{mtga_match_id: nil} = event) do
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

  # ── Serialization ────────────────────────────────────────────────────

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
```

- [ ] **Step 4: Write tests for apply_event**

Create `test/scry_2/events/ingestion_state_test.exs`:

```elixir
defmodule Scry2.Events.IngestionStateTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.IngestionState
  alias Scry2.Events.IngestionState.{Match, Session}
  alias Scry2.TestFactory

  describe "new/1" do
    test "returns fresh state" do
      state = IngestionState.new()
      assert state.version == 1
      assert state.last_raw_event_id == 0
      assert state.session == %Session{}
      assert state.match == %Match{}
    end

    test "seeds self_user_id" do
      state = IngestionState.new(self_user_id: "abc")
      assert state.session.self_user_id == "abc"
    end
  end

  describe "advance/2" do
    test "updates last_raw_event_id" do
      state = IngestionState.new() |> IngestionState.advance(42)
      assert state.last_raw_event_id == 42
    end
  end

  describe "apply_event — session scope" do
    test "SessionStarted sets self_user_id and session_id" do
      event = TestFactory.build_session_started(%{
        client_id: "user-abc",
        session_id: "sess-1"
      })

      {state, side_effects} = IngestionState.apply_event(IngestionState.new(), event)

      assert state.session.self_user_id == "user-abc"
      assert state.session.current_session_id == "sess-1"
      # player_id is NOT set by apply_event — IngestRawEvents resolves it
      # via Players.find_or_create! (side effect) and sets it directly.
      assert state.session.player_id == nil
      assert side_effects == []
    end
  end

  describe "apply_event — match scope" do
    test "MatchCreated sets current_match_id" do
      event = TestFactory.build_match_created(%{mtga_match_id: "match-1"})
      {state, []} = IngestionState.apply_event(IngestionState.new(), event)
      assert state.match.current_match_id == "match-1"
    end

    test "MatchCreated emits pending_deck as side effect" do
      pending = %Scry2.Events.Deck.DeckSubmitted{
        mtga_match_id: nil,
        mtga_deck_id: "pending:seat1",
        main_deck: [],
        sideboard: [],
        occurred_at: ~U[2026-04-08 12:00:00Z]
      }

      state = %{IngestionState.new() | match: %Match{pending_deck: pending}}
      event = TestFactory.build_match_created(%{mtga_match_id: "match-1"})
      {new_state, [deck]} = IngestionState.apply_event(state, event)

      assert deck.mtga_match_id == "match-1"
      assert deck.mtga_deck_id == "match-1:seat1"
      assert new_state.match.pending_deck == nil
    end

    test "DeckSelected sets last_deck_name" do
      event = %Scry2.Events.Deck.DeckSelected{
        event_name: "QuickDraft_FDN",
        deck_name: "My Green Deck",
        main_deck: [],
        occurred_at: ~U[2026-04-08 12:00:00Z]
      }

      {state, []} = IngestionState.apply_event(IngestionState.new(), event)
      assert state.match.last_deck_name == "My Green Deck"
    end

    test "DieRolled sets on_play_for_current_game" do
      event = TestFactory.build_die_rolled(%{self_goes_first: true})
      {state, []} = IngestionState.apply_event(IngestionState.new(), event)
      assert state.match.on_play_for_current_game == true
    end

    test "DeckSubmitted with match_id increments game number" do
      event = TestFactory.build_deck_submitted(%{mtga_match_id: "match-1"})
      {state, []} = IngestionState.apply_event(IngestionState.new(), event)
      assert state.match.current_game_number == 1
    end

    test "DeckSubmitted with nil match_id caches as pending" do
      event = TestFactory.build_deck_submitted(%{mtga_match_id: nil})
      {state, []} = IngestionState.apply_event(IngestionState.new(), event)
      assert state.match.pending_deck == event
    end

    test "MatchCompleted resets match scope" do
      state = %{IngestionState.new() | match: %Match{current_match_id: "m-1", current_game_number: 2}}
      event = TestFactory.build_match_completed()
      {new_state, []} = IngestionState.apply_event(state, event)

      assert new_state.match == %Match{}
      # Session survives
      assert new_state.session == state.session
    end

    test "unknown event is a no-op" do
      {state, []} = IngestionState.apply_event(IngestionState.new(), :whatever)
      assert state == IngestionState.new()
    end
  end

  describe "serialization round-trip" do
    test "from_map/1 restores a serialized state" do
      original = %IngestionState{
        version: 1,
        last_raw_event_id: 42,
        session: %Session{self_user_id: "user-1", player_id: 3, constructed_rank: "Gold 1"},
        match: %Match{current_match_id: "m-abc", current_game_number: 2}
      }

      json = Jason.encode!(original)
      restored = IngestionState.from_map(Jason.decode!(json))

      assert restored.version == 1
      assert restored.last_raw_event_id == 42
      assert restored.session.self_user_id == "user-1"
      assert restored.session.player_id == 3
      assert restored.match.current_match_id == "m-abc"
      assert restored.match.current_game_number == 2
    end

    test "from_map/1 with nil returns fresh state" do
      assert IngestionState.from_map(nil) == IngestionState.new()
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/scry_2/events/ingestion_state_test.exs -v`

Note: Some tests may need factory functions that don't exist yet (e.g. `build_session_started`, `build_die_rolled`, `build_deck_submitted`). If missing, add them to `test/support/factory.ex` following the existing `build_*` pattern. Check the factory first — most of these already exist.

- [ ] **Step 6: Compile with warnings-as-errors**

Run: `MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warnings-as-errors`

- [ ] **Step 7: Commit**

```
jj describe -m "feat: add IngestionState struct with Session/Match sub-structs and apply_event"
jj new
```

---

### Task 2: Create the persistence layer

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_create_ingestion_state.exs`
- Create: `lib/scry_2/events/ingestion_state/snapshot.ex` (Ecto schema)
- Modify: `lib/scry_2/events/ingestion_state.ex` (add `persist!/1`, `load/0`)
- Test: `test/scry_2/events/ingestion_state_test.exs` (add persistence tests)

- [ ] **Step 1: Create the migration**

```elixir
defmodule Scry2.Repo.Migrations.CreateIngestionState do
  use Ecto.Migration

  def change do
    create table(:ingestion_state) do
      add :version, :integer, null: false, default: 1
      add :last_raw_event_id, :integer, null: false, default: 0
      add :session, :map, null: false, default: %{}
      add :match, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end
  end
end
```

- [ ] **Step 2: Create the Snapshot Ecto schema**

Create `lib/scry_2/events/ingestion_state/snapshot.ex`:

```elixir
defmodule Scry2.Events.IngestionState.Snapshot do
  @moduledoc """
  Ecto schema for the singleton `ingestion_state` row.
  Serialization bridge between the `%IngestionState{}` struct and SQLite.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "ingestion_state" do
    field :version, :integer, default: 1
    field :last_raw_event_id, :integer, default: 0
    field :session, :map, default: %{}
    field :match, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:version, :last_raw_event_id, :session, :match])
    |> validate_required([:version, :last_raw_event_id])
  end
end
```

- [ ] **Step 3: Add persist!/1 and load/0 to IngestionState**

Add these functions to `lib/scry_2/events/ingestion_state.ex`:

```elixir
  alias Scry2.Events.IngestionState.Snapshot
  alias Scry2.Repo

  @singleton_id 1

  @doc "Persists the current state to the database."
  def persist!(%__MODULE__{} = state) do
    attrs = %{
      version: state.version,
      last_raw_event_id: state.last_raw_event_id,
      session: Jason.decode!(Jason.encode!(state.session)),
      match: Jason.decode!(Jason.encode!(state.match))
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
  def load do
    case Repo.get(Snapshot, @singleton_id) do
      nil -> new()
      snapshot -> from_map(%{
        "version" => snapshot.version,
        "last_raw_event_id" => snapshot.last_raw_event_id,
        "session" => snapshot.session,
        "match" => snapshot.match
      })
    end
  end
```

- [ ] **Step 4: Write persistence tests**

Add to `test/scry_2/events/ingestion_state_test.exs` (these need `DataCase` — either split into a separate file or change the test module to use DataCase):

Create `test/scry_2/events/ingestion_state_persistence_test.exs`:

```elixir
defmodule Scry2.Events.IngestionStatePersistenceTest do
  use Scry2.DataCase

  alias Scry2.Events.IngestionState
  alias Scry2.Events.IngestionState.{Match, Session}

  describe "persist!/1 and load/0" do
    test "round-trips through the database" do
      state = %IngestionState{
        version: 1,
        last_raw_event_id: 99,
        session: %Session{self_user_id: "user-1", player_id: 5, constructed_rank: "Gold 2"},
        match: %Match{current_match_id: "m-xyz", current_game_number: 1}
      }

      IngestionState.persist!(state)
      loaded = IngestionState.load()

      assert loaded.last_raw_event_id == 99
      assert loaded.session.self_user_id == "user-1"
      assert loaded.session.player_id == 5
      assert loaded.session.constructed_rank == "Gold 2"
      assert loaded.match.current_match_id == "m-xyz"
    end

    test "load/0 returns fresh state when no snapshot exists" do
      assert IngestionState.load() == IngestionState.new()
    end

    test "persist!/1 overwrites existing snapshot" do
      IngestionState.persist!(%IngestionState{last_raw_event_id: 1, session: %Session{}, match: %Match{}})
      IngestionState.persist!(%IngestionState{last_raw_event_id: 2, session: %Session{}, match: %Match{}})

      loaded = IngestionState.load()
      assert loaded.last_raw_event_id == 2
    end
  end
end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/scry_2/events/ingestion_state_test.exs test/scry_2/events/ingestion_state_persistence_test.exs -v`

- [ ] **Step 6: Commit**

```
jj describe -m "feat: add ingestion state persistence — snapshot table, persist!/1, load/0"
jj new
```

---

### Task 3: Wire IngestRawEvents to use IngestionState

**Files:**
- Modify: `lib/scry_2/events/ingest_raw_events.ex`
- Modify: `lib/scry_2/events/enrich_events.ex` (update state access patterns)
- Modify: `test/scry_2/events/ingest_raw_events_test.exs`

This is the main refactor. IngestRawEvents becomes thin wiring around IngestionState.

- [ ] **Step 1: Update init/1 to load persisted state**

Replace the current `init/1` in `ingest_raw_events.ex`:

```elixir
  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.mtga_logs_events())
    state = IngestionState.load(self_user_id: Config.get(:mtga_self_user_id))
    {:ok, state, {:continue, :catch_up}}
  end

  @impl true
  def handle_continue(:catch_up, state) do
    state = catch_up_unprocessed(state)
    {:noreply, state}
  end
```

Add the `IngestionState.load/1` variant that seeds `self_user_id` if no snapshot exists:

In `ingestion_state.ex`, update `load/0` to accept opts:

```elixir
  def load(opts \\ []) do
    case Repo.get(Snapshot, @singleton_id) do
      nil -> new(opts)
      snapshot -> from_map(%{...})  # same as before
    end
  end
```

- [ ] **Step 2: Add catch_up_unprocessed/1**

Add to `ingest_raw_events.ex`:

```elixir
  defp catch_up_unprocessed(state) do
    unprocessed = MtgaLogIngestion.list_unprocessed_after(state.last_raw_event_id)

    case unprocessed do
      [] ->
        state

      records ->
        Log.info(:ingester, "catching up #{length(records)} unprocessed raw events from id=#{state.last_raw_event_id}")
        Enum.reduce(records, state, fn record, acc ->
          try do
            process_raw_event(record, acc)
          rescue
            error ->
              Log.error(:ingester, "catch-up failed on id=#{record.id}: #{inspect(error)}")
              MtgaLogIngestion.mark_error!(record.id, error)
              acc
          end
        end)
    end
  end
```

This requires adding `list_unprocessed_after/1` to `Scry2.MtgaLogIngestion`:

```elixir
  def list_unprocessed_after(last_raw_event_id) do
    EventRecord
    |> where([e], e.id > ^last_raw_event_id and e.processed == false)
    |> order_by([e], asc: e.id)
    |> Repo.all()
  end
```

- [ ] **Step 3: Refactor process_raw_event to use IngestionState**

Replace the state management in `process_raw_event/2`. The key changes:
- `state.self_user_id` → `state.session.self_user_id`
- `state.match_context` → `state.match` (the `%Match{}` struct supports bracket access, so the translator's `match_context[:current_match_id]` still works)
- `update_state(state, events)` → `Enum.reduce(events, state, &apply_and_collect/2)`
- `split_pending_decks` / `maybe_emit_pending_deck` → handled by `IngestionState.apply_event/2`
- `state.player_id` → `state.session.player_id`
- `state.current_session_id` → `state.session.current_session_id`
- After processing, call `IngestionState.advance(state, record.id) |> IngestionState.persist!()`

The `maybe_cache_game_objects` and `maybe_capture_rank` functions stay in IngestRawEvents but update the struct fields:
- `put_in(state, [:match_context, :last_hand_game_objects], resolved)` → `put_in(state.match.last_hand_game_objects, resolved)`
- `%{state | constructed_rank: ...}` → `put_in(state.session.constructed_rank, ...)`

- [ ] **Step 4: Update EnrichEvents state access**

In `enrich_events.ex`, the enrichment functions read state via bracket access:
- `state[:limited_rank]` → `state.session.limited_rank`
- `state[:constructed_rank]` → `state.session.constructed_rank`
- `get_in(state, [:match_context, :last_deck_name])` → `state.match.last_deck_name`
- `get_in(state, [:match_context, :on_play_for_current_game])` → `state.match.on_play_for_current_game`

- [ ] **Step 5: Update the translator call**

The translator's third argument is typed as `match_context()` — a map with `:current_match_id`, `:last_hand_game_objects`. The `%Match{}` struct supports bracket access, so passing `state.match` works without changing the translator:

```elixir
  IdentifyDomainEvents.translate(record, state.session.self_user_id, state.match)
```

- [ ] **Step 6: Run all existing tests**

Run: `mix test`

All existing IngestRawEvents tests should pass — the external behavior is identical, only the internal state representation changed.

- [ ] **Step 7: Compile with warnings-as-errors**

Run: `MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warnings-as-errors`

- [ ] **Step 8: Commit**

```
jj describe -m "refactor: wire IngestRawEvents to use IngestionState struct with persistence"
jj new
```

---

### Task 4: Add startup resume tests

**Files:**
- Modify: `test/scry_2/events/ingest_raw_events_test.exs`

- [ ] **Step 1: Test that init loads persisted state**

```elixir
  describe "startup resume" do
    test "loads persisted state on init", %{worker: _worker, projector: projector} do
      # Persist a state with a known player_id
      alias Scry2.Events.IngestionState
      alias Scry2.Events.IngestionState.Session
      IngestionState.persist!(%IngestionState{
        last_raw_event_id: 0,
        session: %Session{self_user_id: "known-user", player_id: 42},
        match: %Scry2.Events.IngestionState.Match{}
      })

      # Start a fresh worker — it should load the snapshot
      resume_name = Module.concat(__MODULE__, :"Resume#{System.unique_integer([:positive])}")
      _pid = start_supervised!({IngestRawEvents, name: resume_name})

      # Feed a match event — it should use the persisted player_id
      raw = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      sync_pipeline(resume_name, projector)

      match = Matches.get_by_mtga_id("008b1926-09a8-40b4-872d-fa987588740c")
      assert match != nil
      assert match.player_id == 42
    end
  end
```

- [ ] **Step 2: Test catch-up on init**

```elixir
    test "catches up unprocessed events on init" do
      # Insert a raw event but don't start a worker yet
      raw = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      assert MtgaLogIngestion.get_event!(raw.id).processed == false

      # Start worker — it should catch up and process the event
      catchup_name = Module.concat(__MODULE__, :"Catchup#{System.unique_integer([:positive])}")
      proj_name = Module.concat(__MODULE__, :"CatchupProj#{System.unique_integer([:positive])}")
      _proj = start_supervised!({UpdateFromEvent, name: proj_name})
      _worker = start_supervised!({IngestRawEvents, name: catchup_name})

      # Give catch_up time to run
      Process.sleep(100)

      assert MtgaLogIngestion.get_event!(raw.id).processed == true
      assert Events.count_by_type()["match_created"] == 1
    end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/scry_2/events/ingest_raw_events_test.exs -v`

- [ ] **Step 4: Run full suite**

Run: `mix test`

- [ ] **Step 5: Commit**

```
jj describe -m "test: add startup resume and catch-up tests for IngestRawEvents"
jj new
```

---

### Task 5: Update reingest to reset the snapshot

**Files:**
- Modify: `lib/scry_2/events.ex` (update `reingest!/0`)
- Modify: `lib/scry_2/operations.ex` (update `reingest_with_progress/0`)

- [ ] **Step 1: Reset snapshot in reingest!/0**

In `lib/scry_2/events.ex`, add snapshot reset at the start of `reingest!/0`:

```elixir
  def reingest! do
    require Scry2.Log, as: Log
    Log.info(:ingester, "reingest: starting full reingest from raw events")

    # 0. Reset ingestion state snapshot
    Repo.delete_all(IngestionState.Snapshot)

    # 1. Clear domain events (existing code)
    Repo.delete_all(EventRecord)
    # ... rest unchanged
```

- [ ] **Step 2: Same in operations.ex reingest_with_progress/0**

Add `Scry2.Repo.delete_all(Scry2.Events.IngestionState.Snapshot)` at the start of `reingest_with_progress/0`, before clearing domain events.

- [ ] **Step 3: Run full suite**

Run: `mix test`

- [ ] **Step 4: Commit**

```
jj describe -m "feat: reset ingestion state snapshot during reingest"
jj new
```

---

### Task 6: Final verification

- [ ] **Step 1: Run mix precommit**

Run: `mix precommit`

Expected: Zero warnings, all tests pass.

- [ ] **Step 2: Restart dev server and verify**

```bash
systemctl --user restart scry-2-dev
```

Check the ops page — the ingestion state snapshot should be visible. Trigger a reingest and verify all matches have correct `deck_colors`.

- [ ] **Step 3: Verify mid-match resume**

If possible: start watching a log file, let some events process, restart the dev server, verify the state survives by checking the snapshot table and that new events are processed correctly.

- [ ] **Step 4: Commit any cleanup**

```
jj describe -m "chore: final cleanup for durable ingestion state"
```
