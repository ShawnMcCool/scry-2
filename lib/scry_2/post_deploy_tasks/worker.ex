defmodule Scry2.PostDeployTasks.Worker do
  @moduledoc """
  Oban worker that executes a single post-deploy task.

  The job's `args` carry the `task_id`. The worker looks up the task
  module via `Scry2.PostDeployTasks.lookup/1`, invokes its `run/0`,
  and on success calls `Scry2.PostDeployTasks.mark_applied!/1`.
  Failures bubble up to Oban for retry; an exhausted job is visible
  in the **Operations** UI as `:failed`.

  Uniqueness is keyed on the full `args` map (so the same `task_id`
  is not enqueued twice within a 60-second window) but does not
  prevent legitimate re-runs from the UI after the prior run finished.
  """

  use Oban.Worker,
    queue: :imports,
    max_attempts: 3,
    unique: [period: 60, fields: [:args]]

  alias Scry2.PostDeployTasks

  require Scry2.Log, as: Log

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}}) do
    case PostDeployTasks.lookup(task_id) do
      nil ->
        Log.error(:importer, "post-deploy task #{task_id} has no registered module")
        {:error, :unknown_task}

      module ->
        case module.run() do
          :ok ->
            PostDeployTasks.mark_applied!(task_id)
            Log.info(:importer, "post-deploy task #{task_id} applied")
            :ok

          {:error, reason} = err ->
            Log.error(
              :importer,
              "post-deploy task #{task_id} failed: #{inspect(reason)}"
            )

            err
        end
    end
  end
end
