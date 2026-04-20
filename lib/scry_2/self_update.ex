defmodule Scry2.SelfUpdate do
  @moduledoc """
  Public facade for the self-update subsystem.

  The subsystem runs unconditionally in `:prod`; in `:dev` and `:test` it
  is inert (no cron firings, `apply_pending/0` still callable for test
  injection). `enabled?/0` is the single compile-time gate.

  ## Surface

    - `current_version/0` — running code version
    - `cached_release/0` — latest known release from the cache
    - `last_check_at/0` — ISO8601 timestamp of last check (or nil)
    - `check_now/0` — enqueue a manual Oban check
    - `apply_pending/0` — kick off an apply; updates Settings UI via PubSub
    - `current_status/0` — Updater state machine status
    - `subscribe_status/0` — subscribe to check-result broadcasts
    - `subscribe_progress/0` — subscribe to apply-phase broadcasts
    - `enabled?/0` — true iff prod build
    - `boot!/0` — called from Application.start; hydrates cache + clears stale locks
  """

  alias Scry2.Platform
  alias Scry2.SelfUpdate.ApplyLock
  alias Scry2.SelfUpdate.Storage
  alias Scry2.SelfUpdate.Updater
  alias Scry2.SelfUpdate.UpdateChecker
  alias Scry2.Topics
  alias Scry2.Version

  @enabled Mix.env() == :prod
  @stale_lock_seconds 900

  @spec enabled?() :: boolean()
  def enabled?, do: @enabled

  @spec current_version() :: String.t()
  def current_version, do: Version.current()

  @spec apply_lock_path() :: Path.t()
  def apply_lock_path, do: Path.join(Platform.data_dir(), "apply.lock")

  @spec staging_root() :: Path.t()
  def staging_root, do: Path.join(Platform.data_dir(), "update_staging")

  @spec cached_release() :: {:ok, UpdateChecker.release()} | :none
  def cached_release, do: UpdateChecker.cached_latest_release()

  @spec subscribe_status() :: :ok | {:error, term()}
  def subscribe_status, do: Topics.subscribe(Topics.updates_status())

  @spec subscribe_progress() :: :ok | {:error, term()}
  def subscribe_progress, do: Topics.subscribe(Topics.updates_progress())

  @spec check_now() :: {:ok, Oban.Job.t()} | {:error, term()}
  def check_now do
    %{"trigger" => "manual"}
    |> Scry2.SelfUpdate.CheckerJob.new()
    |> Oban.insert()
  end

  @spec apply_pending() :: :ok | {:error, term()}
  def apply_pending, do: Updater.apply_pending()

  @spec current_status() :: map()
  def current_status, do: Updater.status()

  @spec last_check_at() :: String.t() | nil
  def last_check_at, do: Storage.last_check_at()

  @doc """
  Called from `Scry2.Application.start/2`. Idempotent.

  - Ensures the data directory exists (defensive; subdirectories may not
    exist on a fresh install or CI runner).
  - Clears any stale apply lock left behind by a crashed prior apply.
  - Hydrates the UpdateChecker cache from persisted Storage (prod/dev only).

  Hydration is skipped in the `:test` env because Application.start runs
  outside any Ecto sandbox checkout — the Repo query would block for the
  full pool queue timeout before failing. Tests that care about hydration
  exercise `Storage.hydrate!/0` directly.
  """
  @spec boot!() :: :ok
  def boot! do
    _ = File.mkdir_p(Path.dirname(apply_lock_path()))
    _ = ApplyLock.clear_if_stale!(apply_lock_path(), @stale_lock_seconds)
    maybe_hydrate()
    :ok
  end

  if Mix.env() == :test do
    defp maybe_hydrate, do: :ok
  else
    defp maybe_hydrate do
      try do
        :ok = Storage.hydrate!()
      rescue
        error ->
          require Scry2.Log, as: Log
          Log.warning(:system, fn -> "self-update hydrate skipped: #{inspect(error)}" end)
          :ok
      end
    end
  end
end
