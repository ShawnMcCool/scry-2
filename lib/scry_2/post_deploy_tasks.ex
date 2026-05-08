defmodule Scry2.PostDeployTasks do
  @moduledoc """
  Registry and runner for post-deploy data tasks — one-shot work that
  must run on first boot after an upgrade introduces it.

  Schema migrations handle table shape; **post-deploy tasks** handle
  table contents. They cover situations where a code change requires
  re-running synthesis, rebuilding a projection, or similar — work that
  schema migrations cannot perform because it depends on application
  modules that don't exist at migration time.

  ## Pipeline

  1. Application boot enqueues `run!/0` once after Oban is ready (one-shot
     `Task` child in the supervisor).
  2. `run!/0` iterates `registered_tasks/0`. For each task with no
     `applied_at` recorded in `Settings`, it enqueues a
     `Scry2.PostDeployTasks.Worker` job carrying the task's `task_id`.
  3. The worker invokes the task module's `run/0`. On `:ok` it calls
     `mark_applied!/1`, which writes
     `"post_deploy.<task_id>.applied_at"` to `Settings`. Subsequent
     boots see the marker and skip the task.
  4. **Settings → Operations** lists every registered task with its
     status (`:pending | :running | :applied | :failed`) and exposes a
     manual "Re-run" button that drops the marker and re-enqueues.

  ## Adding a new task

  1. Create a module under `Scry2.PostDeployTasks.Tasks.*` that
     implements `Scry2.PostDeployTasks.Task`. Bake the version into
     `task_id/0` (e.g. `"matches.rebuild_v1"`).
  2. Add the module to `@registered_tasks` below.
  3. Write a focused test under
     `test/scry_2/post_deploy_tasks/tasks/`.

  No release-management ceremony required — the task fires automatically
  on the first boot after deployment, and the **Operations** card gives
  the user visibility and recovery.

  ## Why not schema migrations

  Migrations run inside Ecto without the rest of the application
  compiled or supervised, so they cannot call context modules, enqueue
  Oban jobs, or use PubSub. Anything that needs the application alive
  must run as a post-deploy task instead. Migrations stay reserved for
  schema changes and SQL-only data backfills.
  """

  alias Scry2.Config
  alias Scry2.PostDeployTasks.Worker
  alias Scry2.Settings

  require Scry2.Log, as: Log

  @type task_id :: String.t()
  @type status :: :pending | :running | :applied | :failed
  @type entry :: %{
          id: task_id(),
          module: module(),
          description: String.t(),
          applied_at: DateTime.t() | nil,
          status: status()
        }

  @registered_tasks [
    Scry2.PostDeployTasks.Tasks.SynthesisAlgoV2
  ]

  @applied_at_prefix "post_deploy."
  @applied_at_suffix ".applied_at"

  @doc "Registered task modules in declaration order."
  @spec registered_tasks() :: [module()]
  def registered_tasks, do: @registered_tasks

  @doc """
  Enqueues a `Scry2.PostDeployTasks.Worker` job for every registered
  task whose `applied_at` marker is absent. Returns the list of
  enqueued `task_id`s. Called once at boot via the application
  supervisor.

  Gated on `Scry2.Config.get(:start_importer)` — when importers are
  disabled (test env, opt-out installs) this is a no-op, since most
  tasks invoke importers/synthesis/projection rebuilds that require
  the broader application surface to be live.
  """
  @spec run!() :: [task_id()]
  def run! do
    if Config.get(:start_importer) == false do
      Log.info(:importer, "post-deploy tasks skipped (start_importer=false)")
      []
    else
      for module <- @registered_tasks, not applied?(module.task_id()) do
        enqueue!(module.task_id())
        module.task_id()
      end
    end
  end

  @doc """
  Enqueues a worker for `task_id` regardless of whether it's already
  been applied. Used by the UI's "Re-run" button. The applied marker
  is dropped first so the task is treated as pending again until the
  worker finishes.
  """
  @spec rerun!(task_id()) :: :ok
  def rerun!(task_id) when is_binary(task_id) do
    Settings.delete(applied_at_key(task_id))
    enqueue!(task_id)
    :ok
  end

  @doc """
  Records that `task_id` finished successfully. Called by the worker
  on `:ok`; never called directly by tasks. Stores the current UTC
  timestamp as ISO8601 under `"post_deploy.<task_id>.applied_at"`.
  """
  @spec mark_applied!(task_id()) :: :ok
  def mark_applied!(task_id) when is_binary(task_id) do
    Settings.put!(
      applied_at_key(task_id),
      DateTime.utc_now() |> DateTime.to_iso8601()
    )

    :ok
  end

  @doc "Returns the task module registered with this `task_id`, or `nil`."
  @spec lookup(task_id()) :: module() | nil
  def lookup(task_id) when is_binary(task_id) do
    Enum.find(@registered_tasks, fn module -> module.task_id() == task_id end)
  end

  @doc """
  Returns one entry per registered task with its current status.
  Used by the **Operations** LiveView card.
  """
  @spec list() :: [entry()]
  def list do
    job_states = job_states_by_task_id()

    for module <- @registered_tasks do
      task_id = module.task_id()
      applied = applied_at(task_id)

      %{
        id: task_id,
        module: module,
        description: module.description(),
        applied_at: applied,
        status: classify(applied, Map.get(job_states, task_id))
      }
    end
  end

  @doc "True when `task_id` has been applied at least once."
  @spec applied?(task_id()) :: boolean()
  def applied?(task_id) when is_binary(task_id), do: applied_at(task_id) != nil

  defp applied_at_key(task_id), do: @applied_at_prefix <> task_id <> @applied_at_suffix

  defp applied_at(task_id) do
    case Settings.get(applied_at_key(task_id)) do
      nil ->
        nil

      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _} -> dt
          _ -> nil
        end
    end
  end

  defp enqueue!(task_id) do
    Oban.insert!(Worker.new(%{task_id: task_id}))
  end

  # Pure: chooses the status from the applied-at marker and the most
  # recent Oban job state for this task_id.
  @doc false
  @spec classify(DateTime.t() | nil, atom() | nil) :: status()
  def classify(applied_at, job_state)

  def classify(_applied_at, state) when state in [:executing, :scheduled, :available, :retryable],
    do: :running

  def classify(_applied_at, :discarded), do: :failed
  def classify(%DateTime{}, _state), do: :applied
  def classify(nil, _state), do: :pending

  # Returns %{task_id => most-recent-job-state} for our worker. State
  # ordering: in-flight states win over terminal states; among in-flight
  # states the most recent wins. Implemented in SQL to keep boot/UI
  # cheap (no Repo.all over every Oban job).
  defp job_states_by_task_id do
    import Ecto.Query

    worker_name = Atom.to_string(Worker)

    query =
      from(j in Oban.Job,
        where: j.worker == ^worker_name,
        select: {fragment("json_extract(?, '$.task_id')", j.args), j.state, j.id}
      )

    Scry2.Repo.all(query)
    |> Enum.reject(fn {task_id, _, _} -> is_nil(task_id) end)
    |> Enum.group_by(fn {task_id, _, _} -> task_id end)
    |> Map.new(fn {task_id, rows} ->
      # Newest job wins (highest id). State coerced to atom for matching.
      {state, _id} =
        rows
        |> Enum.map(fn {_, state, id} -> {String.to_existing_atom(state), id} end)
        |> Enum.max_by(fn {_, id} -> id end)

      {task_id, state}
    end)
  end
end
