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
  Launches a projection rebuild in the background for the given modules
  (defaults to all projectors).
  """
  def start_rebuild!(projector_modules \\ ProjectorRegistry.all()) do
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
  Launches a projection catch-up in the background for the given modules
  (defaults to all projectors).
  """
  def start_catch_up!(projector_modules \\ ProjectorRegistry.all()) do
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

  # ── Background work with progress ──────────────────────────────────

  defp reingest_with_progress do
    alias Scry2.Events.IngestRawEvents

    # Reset domain events and ingestion state.
    Scry2.Repo.delete_all(Scry2.Events.IngestionState.Snapshot)
    Scry2.Repo.delete_all(Events.EventRecord)

    Scry2.MtgaLogIngestion.EventRecord
    |> Scry2.Repo.update_all(set: [processed: false, processed_at: nil, processing_error: nil])

    # Suspend live projectors — avoids redundant projection writes while
    # retranslating. Phase 2 (rebuild_with_progress) rebuilds everything
    # from scratch anyway.
    Enum.each(ProjectorRegistry.all(), fn mod ->
      case Process.whereis(mod) do
        nil -> :ok
        _pid -> mod.suspend_live()
      end
    end)

    # Phase 1: Retranslate every raw event synchronously.
    # IngestRawEvents.retranslate_all! processes each event inside the GenServer
    # and calls on_progress after each one — accurate per-event tracking with
    # no polling and no race conditions.
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

    Enum.each(ProjectorRegistry.all(), fn mod ->
      case Process.whereis(mod) do
        nil -> :ok
        _pid -> mod.resume_live()
      end
    end)

    # Phase 2: Rebuild all projections from the fresh domain event log.
    rebuild_with_progress(ProjectorRegistry.all())
  end

  defp rebuild_with_progress(projector_modules) do
    projector_count = length(projector_modules)

    projector_modules
    |> Enum.with_index(1)
    |> Enum.each(fn {mod, index} ->
      name = mod.projector_name()

      mod.rebuild!(
        on_progress: fn processed, total ->
          broadcast_progress(:rebuild, %{
            phase: :projection,
            current_projector: name,
            projector_index: index,
            projector_total: projector_count,
            processed: processed,
            total: total,
            percent: percent(processed, total)
          })
        end
      )
    end)
  end

  defp catch_up_with_progress(projector_modules) do
    projector_count = length(projector_modules)

    projector_modules
    |> Enum.with_index(1)
    |> Enum.each(fn {mod, index} ->
      name = mod.projector_name()

      mod.catch_up!(
        on_progress: fn processed, total ->
          broadcast_progress(:catch_up, %{
            phase: :projection,
            current_projector: name,
            projector_index: index,
            projector_total: projector_count,
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

  defp broadcast_started(type, metadata) do
    Topics.broadcast(Topics.operations(), {:operation_started, type, metadata})
  end

  defp broadcast_progress(type, progress) do
    Topics.broadcast(Topics.operations(), {:operation_progress, type, progress})
  end

  defp broadcast_completed(type) do
    Topics.broadcast(Topics.operations(), {:operation_completed, type})
  end

  defp broadcast_failed(type, reason) do
    Topics.broadcast(Topics.operations(), {:operation_failed, type, reason})
  end
end
