defmodule Scry2.PostDeployTasks.Task do
  @moduledoc """
  Behaviour for post-deploy tasks — one-shot data work that must run
  on first boot after an upgrade introduces it.

  A task module declares its identity (`task_id/0`), a human-readable
  description for the **Settings → Operations** UI, and the work to do
  (`run/0`). The framework — `Scry2.PostDeployTasks` — handles
  idempotency (via `Settings`), enqueueing onto Oban, status reporting,
  and manual re-run.

  ## Versioning

  Bake the version into the `task_id`. The first version of the
  synthesis re-run is `"synthesis.algo_v2"`; if the synthesis algorithm
  changes again in a way that requires another re-run, register a new
  task module with `task_id/0 == "synthesis.algo_v3"`. Each version is
  independently tracked, so a user upgrading across multiple releases
  picks up every task they've missed.

  Never reuse a `task_id` for different work — the applied-at marker
  for the old work would silently suppress the new work.

  ## Contract

  `run/0` must be safely re-runnable. The framework can re-invoke it
  from the **Operations** UI's "Re-run" button. Return `:ok` on
  success or `{:error, term()}` on failure (Oban retries failures up
  to the worker's `max_attempts`).
  """

  @callback task_id() :: String.t()
  @callback description() :: String.t()
  @callback run() :: :ok | {:error, term()}
end
