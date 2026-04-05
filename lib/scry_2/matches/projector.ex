defmodule Scry2.Matches.Projector do
  @moduledoc """
  Pipeline stage 09 — project domain events into the `matches_*` read
  models.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `{:domain_event, id, type_slug}` messages on `domain:events` |
  | **Output** | Rows in `matches_matches` via `Scry2.Matches.upsert_match!/1` + broadcasts on `matches:updates` |
  | **Nature** | GenServer (subscribes at init) |
  | **Called from** | Broadcast from `Scry2.Events.append!/2` |
  | **Calls** | `Scry2.Events.get!/1` → `Scry2.Matches.upsert_match!/1` |

  ## Claimed domain events

  Only events whose `type_slug` is in `@claimed_slugs` trigger a
  projection update. Other events are silently ignored (this is how
  multiple projectors can share a single `domain:events` topic without
  stepping on each other).

  Current claims:

    * `"match_created"` → `%Scry2.Events.MatchCreated{}` → upsert a new
      row in `matches_matches` with opponent name, event name, started_at.
    * `"match_completed"` → `%Scry2.Events.MatchCompleted{}` → enrich
      the existing row with ended_at, won, num_games.

  ## Idempotency

  Projections MUST be idempotent — replaying the same domain event
  twice produces the same row state. This is guaranteed by `upsert_match!/1`
  using `mtga_match_id` as the conflict target (ADR-016). The projector
  itself contains no state; everything flows through the DB upsert.

  ## Failure handling

  Handler errors are caught and logged. The projector never crashes on
  a malformed event — the projection table can be rebuilt from the
  event log via `Scry2.Events.replay_projections!/0`, so eventual
  consistency is tolerable.
  """
  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Events
  alias Scry2.Events.{MatchCompleted, MatchCreated}
  alias Scry2.Matches
  alias Scry2.Topics

  @claimed_slugs ~w(match_created match_completed)

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.domain_events())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:domain_event, id, type_slug}, state) when type_slug in @claimed_slugs do
    try do
      event = Events.get!(id)
      project(event)
    rescue
      error ->
        Log.error(
          :ingester,
          "matches projector failed on domain_event id=#{id} type=#{type_slug}: #{inspect(error)}"
        )
    end

    {:noreply, state}
  end

  def handle_info({:domain_event, _id, _type_slug}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # ── Projection handlers ─────────────────────────────────────────────
  #
  # One clause per claimed domain event type. Each handler destructures
  # the event, builds upsert attrs, and writes to the projection table.
  # Idempotency comes from the underlying upsert-by-mtga-id.

  defp project(%MatchCreated{} = event) do
    attrs = %{
      mtga_match_id: event.mtga_match_id,
      event_name: event.event_name,
      opponent_screen_name: event.opponent_screen_name,
      started_at: event.started_at
    }

    match = Matches.upsert_match!(attrs)

    Log.info(
      :ingester,
      "projected MatchCreated mtga_match_id=#{match.mtga_match_id} opponent=#{inspect(event.opponent_screen_name)}"
    )

    :ok
  end

  defp project(%MatchCompleted{} = event) do
    attrs = %{
      mtga_match_id: event.mtga_match_id,
      ended_at: event.ended_at,
      won: event.won,
      num_games: event.num_games
    }

    match = Matches.upsert_match!(attrs)

    Log.info(
      :ingester,
      "projected MatchCompleted mtga_match_id=#{match.mtga_match_id} won=#{event.won} games=#{event.num_games}"
    )

    :ok
  end
end
