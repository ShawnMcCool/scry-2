defmodule Scry2.Operations do
  @moduledoc """
  Launches background pipeline operations (reingest, rebuild, catch-up)
  and broadcasts progress on the `operations:status` PubSub topic.

  Operations run in `Scry2.TaskSupervisor` so they don't block the
  calling process (typically a LiveView). Progress is broadcast
  periodically so subscribers can update their UI in real time.

  ## PubSub messages on `operations:status`

    * `{:operation_started, type, metadata}` — operation kicked off
    * `{:operation_progress, type, progress}` — periodic update
    * `{:operation_completed, type}` — finished successfully
    * `{:operation_failed, type, reason}` — crashed or errored

  ## Contract

  | | |
  |---|---|
  | **Input** | `start_reingest!/0`, `start_rebuild!/1`, `start_catch_up!/1` |
  | **Output** | PubSub broadcasts on `operations:status` |
  | **Nature** | Spawns background tasks; never blocks the caller |
  """

  import Ecto.Query, only: [from: 2]

  require Scry2.Log, as: Log

  alias Scry2.Events
  alias Scry2.Events.ProjectorRegistry
  alias Scry2.MtgaLogIngestion
  alias Scry2.Topics

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Launches a full reingest in the background.

  Phase 1: Clears domain events, re-marks raw events unprocessed,
  re-broadcasts for translation. Polls processed count for progress.

  Phase 2: Rebuilds all projections from the fresh domain event log.
  """
  def start_reingest! do
    names = Enum.map(ProjectorRegistry.all(), & &1.projector_name())
    broadcast_started(:reingest, %{projectors: names})

    Task.Supervisor.async_nolink(Scry2.TaskSupervisor, fn ->
      try do
        reingest_with_progress()
        broadcast_completed(:reingest)
      rescue
        error ->
          Log.error(:ingester, "reingest failed: #{inspect(error)}")
          broadcast_failed(:reingest, inspect(error))
      end
    end)
  end

  @doc """
  Launches a full rebuild of all projections via `domain:control`.

  Broadcasts `:rebuild_all` to all projector GenServers. Each projector
  truncates its tables, replays from scratch, and reports progress and
  completion back on `domain:control`. A coordinator Task collects the
  acks and broadcasts `{:operation_completed, :rebuild}` when all done.
  """
  def start_rebuild! do
    projectors = ProjectorRegistry.all()
    names = Enum.map(projectors, & &1.projector_name())
    broadcast_started(:rebuild, %{projectors: names})

    Task.Supervisor.async_nolink(Scry2.TaskSupervisor, fn ->
      try do
        rebuild_with_progress(projectors, :rebuild)
        broadcast_completed(:rebuild)
      rescue
        error ->
          Log.error(:ingester, "rebuild failed: #{inspect(error)}")
          broadcast_failed(:rebuild, inspect(error))
      end
    end)
  end

  @doc """
  Launches a rebuild for a specific subset of projectors (direct call, no broadcast).
  Used by per-row rebuild actions on the ops page.
  """
  def start_rebuild!(projector_modules) when is_list(projector_modules) do
    names = Enum.map(projector_modules, & &1.projector_name())
    broadcast_started(:rebuild, %{projectors: names})

    Task.Supervisor.async_nolink(Scry2.TaskSupervisor, fn ->
      try do
        rebuild_with_progress(projector_modules)
        broadcast_completed(:rebuild)
      rescue
        error ->
          Log.error(:ingester, "rebuild failed: #{inspect(error)}")
          broadcast_failed(:rebuild, inspect(error))
      end
    end)
  end

  @doc """
  Launches a catch-up of all projections via `domain:control`.

  Same coordination model as `start_rebuild!/0` but replays only missed
  events (from watermark) without truncating tables.
  """
  def start_catch_up! do
    projectors = ProjectorRegistry.all()
    names = Enum.map(projectors, & &1.projector_name())
    broadcast_started(:catch_up, %{projectors: names})

    Task.Supervisor.async_nolink(Scry2.TaskSupervisor, fn ->
      try do
        catch_up_with_progress(projectors)
        broadcast_completed(:catch_up)
      rescue
        error ->
          Log.error(:ingester, "catch-up failed: #{inspect(error)}")
          broadcast_failed(:catch_up, inspect(error))
      end
    end)
  end

  @doc """
  Launches a catch-up for a specific subset of projectors (direct call, no broadcast).
  Used by per-row catch-up actions on the ops page.
  """
  def start_catch_up!(projector_modules) when is_list(projector_modules) do
    names = Enum.map(projector_modules, & &1.projector_name())
    broadcast_started(:catch_up, %{projectors: names})

    Task.Supervisor.async_nolink(Scry2.TaskSupervisor, fn ->
      try do
        catch_up_with_progress(projector_modules)
        broadcast_completed(:catch_up)
      rescue
        error ->
          Log.error(:ingester, "catch-up failed: #{inspect(error)}")
          broadcast_failed(:catch_up, inspect(error))
      end
    end)
  end

  @doc "Returns true if an Oban worker is currently queued or running."
  def oban_running?(worker) do
    worker_name = to_string(worker)

    Scry2.Repo.exists?(
      from j in Oban.Job,
        where: j.worker == ^worker_name and j.state in ["available", "executing", "scheduled"]
    )
  end

  @doc "Returns a status snapshot for the operations page."
  def status do
    %{
      raw_event_count: MtgaLogIngestion.count_all(),
      raw_unprocessed: MtgaLogIngestion.count_unprocessed(),
      domain_event_count: Events.max_event_id(),
      error_count: MtgaLogIngestion.count_errors(),
      projectors: ProjectorRegistry.status_all()
    }
  end

  # ── Background work with progress (subset/single-projector ops) ────

  defp reingest_with_progress do
    alias Scry2.Events.IngestRawEvents

    # Reset domain events and ingestion state.
    Scry2.Repo.delete_all(Scry2.Events.IngestionState.Snapshot)
    Scry2.Repo.delete_all(Events.EventRecord)

    Scry2.MtgaLogIngestion.EventRecord
    |> Scry2.Repo.update_all(set: [processed: false, processed_at: nil, processing_error: nil])

    # Retranslate every raw event synchronously. append_batch! does not broadcast
    # domain:events, so projectors receive no live messages during this phase.
    IngestRawEvents.retranslate_all!(
      on_progress: fn processed, total ->
        report_every = max(1, div(total, 200))

        if rem(processed, report_every) == 0 or processed == total do
          broadcast_progress(:reingest, %{
            phase: :retranslation,
            processed: processed,
            total: total,
            percent: percent(processed, total)
          })
        end
      end
    )

    # Rebuild every projector sequentially in registry order. Concurrent
    # rebuilds (the previous design, broadcasting :full_rebuild) hammered
    # SQLite's connection pool and amplified the per-event broadcast
    # cascade between projectors badly enough to crash the BEAM under
    # full-history reingest. Sequential is slower but bounded; combined
    # with `SilentMode` suppression of cross-projector broadcasts and
    # `post_rebuild/0` batch reconciliation, the pipeline stays inside
    # safe DB-pool and BEAM-supervisor budgets.
    rebuild_with_progress(ProjectorRegistry.all(), :reingest)
  end

  defp rebuild_with_progress(projector_modules, op_type \\ :rebuild) do
    Enum.each(projector_modules, fn mod ->
      name = mod.projector_name()

      mod.rebuild!(
        on_progress: fn processed, total ->
          broadcast_progress(op_type, %{
            phase: :projection,
            projector: name,
            processed: processed,
            total: total,
            percent: percent(processed, total)
          })
        end
      )
    end)
  end

  defp catch_up_with_progress(projector_modules) do
    Enum.each(projector_modules, fn mod ->
      name = mod.projector_name()

      mod.catch_up!(
        on_progress: fn processed, total ->
          broadcast_progress(:catch_up, %{
            phase: :projection,
            projector: name,
            processed: processed,
            total: total,
            percent: percent(processed, total)
          })
        end
      )
    end)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp percent(_done, 0), do: 100
  defp percent(done, total), do: round(done / total * 100)

  # ── Last-operation state ─────────────────────────────────────────────
  #
  # Stored in :persistent_term so a fresh LiveView mount (page reload,
  # WebSocket reconnect) can restore the operation section without a
  # running operation needing to be active. :persistent_term is process-less
  # and survives reconnects; reads are near-zero cost.
  #
  # Written on every start/complete/fail. Reset to nil only on app restart.

  @pt_key {__MODULE__, :last_operation}

  @doc """
  Returns the last known operation state, or `nil` if none has run this session.

  Shape: `%{type: atom, running: boolean}` — enough for the UI to reconstruct
  the section header and completion badge without full step history.
  """
  def last_operation, do: :persistent_term.get(@pt_key, nil)

  defp broadcast_started(type, metadata) do
    :persistent_term.put(@pt_key, %{type: type, running: true})
    Topics.broadcast(Topics.operations(), {:operation_started, type, metadata})
  end

  defp broadcast_progress(type, progress) do
    Topics.broadcast(Topics.operations(), {:operation_progress, type, progress})
  end

  defp broadcast_completed(type) do
    :persistent_term.put(@pt_key, %{type: type, running: false})
    Topics.broadcast(Topics.operations(), {:operation_completed, type})
  end

  defp broadcast_failed(type, reason) do
    :persistent_term.put(@pt_key, %{type: type, running: false})
    Topics.broadcast(Topics.operations(), {:operation_failed, type, reason})
  end
end
