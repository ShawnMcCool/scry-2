defmodule Scry2.SelfUpdate.CheckerJob do
  @moduledoc """
  Oban worker that runs hourly via cron and on demand via "Check now".

  **Deduplication:**
    - The cron-scheduled job uses `args: %{"trigger" => "cron"}` with a
      55-minute `unique` window, so cron scheduling glitches don't stack.
    - The UI enqueues manual checks with `args: %{"trigger" => "manual"}`;
      different args bypass the uniqueness check so a user can always
      force a refresh.

  **Test stubbing:**
    - `Application.get_env(:scry_2, :self_update_req_options, [])` feeds
      extra options (e.g. a `:plug` stub) into `UpdateChecker.latest_release/1`.
      Oban's `testing: :inline` mode executes the worker in the test process,
      and `Req.Test` resolves the stub via caller lookup, so this is all the
      wiring we need. Meta-based threading was considered but rejected because
      Oban JSON-recodes job meta and Plug tuples aren't encodable.
  """

  use Oban.Worker,
    queue: :self_update,
    max_attempts: 3,
    unique: [
      period: 3300,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing]
    ]

  require Scry2.Log, as: Log

  alias Scry2.SelfUpdate.Storage
  alias Scry2.SelfUpdate.UpdateChecker
  alias Scry2.Topics

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    trigger = Map.get(args, "trigger", "unknown")
    req_options = Application.get_env(:scry_2, :self_update_req_options, [])

    Log.info(:system, fn -> "self-update check starting (trigger=#{trigger})" end)

    Topics.broadcast(Topics.updates_status(), :check_started)

    result = UpdateChecker.latest_release(req_options: req_options)
    :ok = Storage.record_check_result(result)
    Topics.broadcast(Topics.updates_status(), {:check_complete, result})

    case result do
      {:ok, release} ->
        Log.info(:system, fn -> "self-update latest=#{release.tag}" end)
        :ok

      {:error, reason} ->
        Log.warning(:system, fn -> "self-update check failed: #{inspect(reason)}" end)
        :ok
    end
  end
end
