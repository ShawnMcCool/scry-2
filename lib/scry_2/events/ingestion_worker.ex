defmodule Scry2.Events.IngestionWorker do
  @moduledoc """
  Pipeline stage 08 — consume raw MTGA events from PubSub, translate to
  domain events, persist to the event log, broadcast to projectors.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `{:event, id, type}` messages on `mtga_logs:events` |
  | **Output** | Persisted rows in `domain_events` + broadcasts on `domain:events` |
  | **Nature** | GenServer (subscribes at init) |
  | **Called from** | Broadcast from `Scry2.MtgaLogs.insert_event!/1` (stage 05 → 08) |
  | **Calls** | `MtgaLogs.get_event!/1` → `Translator.translate/2` (stage 07) → `Events.append!/2` |

  ## Responsibilities

  This is the ONLY subscriber of `mtga_logs:events` in the system.
  Every downstream concern (matches, drafts, analytics, overlays)
  subscribes to `domain:events` instead — the anti-corruption layer
  is enforced at the PubSub boundary, not just in code (ADR-018).

  On each raw event broadcast:

    1. Load the `%EventRecord{}` via `MtgaLogs.get_event!/1`
    2. Feed it through `Translator.translate/2` with the configured
       `mtga_self_user_id`
    3. For each resulting domain event struct, call `Events.append!/2`
    4. Mark the raw event `processed` so it doesn't re-translate on restart

  Translation errors are caught and logged via `MtgaLogs.mark_error!/2`.
  The GenServer never crashes on bad data — malformed events are a
  normal fact of life when mining real logs.

  ## Ordering

  Raw events arrive in the PubSub mailbox in the order `insert_event!/1`
  was called, which matches Player.log byte order. Domain events are
  persisted in the same order (single GenServer → serialized processing).
  This ordering is the basis of `replay_projections!/0` being deterministic.
  """
  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Config
  alias Scry2.Events
  alias Scry2.Events.Translator
  alias Scry2.MtgaLogs
  alias Scry2.Topics

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.mtga_logs_events())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:event, id, type}, state) do
    try do
      process_raw_event(id, type)
      MtgaLogs.mark_processed!(id)
    rescue
      error ->
        Log.error(
          :ingester,
          "ingestion_worker failed to process id=#{id} type=#{type}: #{inspect(error)}"
        )

        MtgaLogs.mark_error!(id, error)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Load the raw event, run it through the translator, append each
  # resulting domain event to the log. Zero domain events is a valid
  # outcome (many raw event types don't map to anything we care about).
  defp process_raw_event(id, type) do
    record = MtgaLogs.get_event!(id)
    self_user_id = Config.get(:mtga_self_user_id)

    domain_events = Translator.translate(record, self_user_id)

    case domain_events do
      [] ->
        :ok

      events ->
        for event <- events do
          Events.append!(event, record)
        end

        Log.info(
          :ingester,
          "translated raw id=#{id} type=#{type} → #{length(events)} domain events"
        )
    end

    :ok
  end
end
