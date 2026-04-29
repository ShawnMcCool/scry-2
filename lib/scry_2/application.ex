defmodule Scry2.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Scry2.Config.load!()

    install_console_handler()
    install_file_log_handler()
    Scry2.Diagnostics.CrashDump.init!()

    children =
      [
        Scry2Web.Telemetry,
        Scry2.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:scry_2, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:scry_2, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Scry2.PubSub},
        # Buffer must start AFTER Repo and PubSub — it reads persisted filter
        # + buffer size from Scry2.Settings in init/1 and broadcasts appends
        # via PubSub. Logs emitted before this starts are dropped silently by
        # Buffer.append/2's Process.whereis guard.
        Scry2.Console.RecentEntries,
        # Card image cache — ensures cache directory exists on startup.
        Scry2.Cards.ImageCache,
        # TaskSupervisor must come BEFORE VersionCheck. A full reingest
        # invokes the projector rebuild via `Task.Supervisor.async_stream(
        # Scry2.TaskSupervisor, …)`; if the supervisor isn't up yet the
        # rebuild crashes with `:no process` and the whole boot fails.
        # TaskSupervisor doesn't touch SQLite, so placing it ahead of
        # VersionCheck doesn't interfere with the write-lock invariant
        # the Oban-after-VersionCheck ordering protects.
        {Task.Supervisor, name: Scry2.TaskSupervisor}
      ]
      |> maybe_add_version_check()
      |> Kernel.++([
        # Oban must come AFTER VersionCheck. If a reingest is needed,
        # VersionCheck holds the SQLite write lock for many chunks; if
        # Oban is already running, its housekeeping queries (job state
        # transitions, beat heartbeats) compete for write transactions
        # on the same connection pool and trip Ecto's checkout timeout.
        # See https://www.sqlite.org/lockingv3.html — only one RESERVED
        # writer at a time, even with WAL.
        {Oban, Application.fetch_env!(:scry_2, Oban)},
        # One-shot task: check for missing/stale card reference data and enqueue
        # refresh jobs immediately rather than waiting for the daily cron window.
        # Must run after Oban is up (so jobs can be inserted). Gated internally
        # on `Scry2.Config.get(:start_importer)` — no-ops in test/disabled envs.
        Supervisor.child_spec({Task, &Scry2.Cards.Bootstrap.run/0},
          id: :cards_bootstrap,
          restart: :temporary
        ),
        {Scry2.SelfUpdate.Updater,
         lock_path: Scry2.SelfUpdate.apply_lock_path(),
         staging_root: Scry2.SelfUpdate.staging_root()},
        Scry2Web.Endpoint
      ])
      |> maybe_add_watcher()

    # Restart intensity defaults are 3 in 5 seconds — too aggressive for
    # this app, where a reingest hammers many child workers at once and
    # transient SQLite/DBConnection contention can produce a quick burst
    # of restarts that doesn't indicate a real failure. 10/30 keeps the
    # safety net (something is genuinely broken if 10 children die in 30
    # seconds) while preventing background-ops blips from killing the VM.
    opts = [
      strategy: :one_for_one,
      name: Scry2.Supervisor,
      max_restarts: 10,
      max_seconds: 30
    ]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        :ok = Scry2.SelfUpdate.boot!()
        {:ok, pid}

      other ->
        other
    end
  end

  # Install the Erlang :logger handler that funnels all log events into
  # Scry2.Console.RecentEntries. Safe to call on reboot — re-adds cleanly if the
  # previous handler was left behind (e.g. after a LiveReload crash).
  defp install_console_handler do
    if Application.get_env(:scry_2, :install_console_handler, true) do
      _ = :logger.remove_handler(:scry2_console)

      :ok =
        :logger.add_handler(
          :scry2_console,
          Scry2.Console.CaptureLogOutput,
          %{level: :all, config: %{}}
        )
    end
  end

  # Persist log entries to disk so they survive BEAM restart — the in-memory
  # Console buffer is wiped when the VM dies, leaving no record of what
  # happened in the moments before a crash. Off by default in test
  # (`config/test.exs` sets `:install_file_log_handler` false). Rotation:
  # 5MB per file, 5 files retained → ~25MB ceiling. `filesync_repeat_interval`
  # forces a fsync every second so the last few seconds of activity before
  # a hard crash actually land on disk (v0.25.7 buffered them and lost
  # the supervisor crash report we needed to diagnose the reingest crash).
  defp install_file_log_handler do
    if Application.get_env(:scry_2, :install_file_log_handler, true) do
      log_path = Path.join([Scry2.Platform.data_dir(), "log", "scry_2.log"])

      case File.mkdir_p(Path.dirname(log_path)) do
        :ok ->
          purge_legacy_disk_log_files(log_path)
          _ = :logger.remove_handler(:scry2_file)

          :ok =
            :logger.add_handler(
              :scry2_file,
              :logger_std_h,
              %{
                level: :info,
                config: %{
                  file: String.to_charlist(log_path),
                  type: :file,
                  max_no_bytes: 5 * 1024 * 1024,
                  max_no_files: 5,
                  filesync_repeat_interval: 1_000
                },
                formatter:
                  Logger.Formatter.new(
                    format: "$time $metadata[$level] $message\n",
                    metadata: [:component, :request_id]
                  )
              }
            )

        {:error, reason} ->
          require Logger

          Logger.warning(
            "file log handler skipped — could not create log dir: #{inspect(reason)}"
          )
      end
    end
  end

  # v0.25.7 used `logger_disk_log_h`, which writes a wrap log split into
  # `<file>.1`, `<file>.2`, plus `<file>.idx` / `<file>.siz` index files.
  # `logger_std_h` uses a different on-disk layout (`<file>`, `<file>.0`,
  # `<file>.1`, …). Leaving the old files around confuses anyone tailing
  # the directory; remove them on first boot of the new format.
  defp purge_legacy_disk_log_files(log_path) do
    [log_path <> ".idx", log_path <> ".siz"]
    |> Enum.each(fn path ->
      _ = File.rm(path)
    end)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Scry2Web.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  # Run the event-pipeline VersionCheck BEFORE Oban and Cards.Bootstrap.
  # `init/1` returns `:ignore` so this never appears in the running
  # supervision tree — but it BLOCKS startup until the reingest finishes,
  # which is exactly what we want: a single SQLite writer with no
  # competition for `BEGIN IMMEDIATE` from job housekeeping or import
  # workers. Gated on `:start_watcher` so the test env (which builds
  # the pipeline ad-hoc per test) skips it.
  defp maybe_add_version_check(children) do
    if Scry2.Config.get(:start_watcher) do
      children ++ [Scry2.Events.VersionCheck]
    else
      children
    end
  end

  # Only add the MTGA log watcher + event-sourced pipeline if configuration
  # says so. Off by default in the test env (see config/test.exs) so tests
  # can start pieces of the pipeline explicitly via the public API when
  # they need to.
  #
  # Child order matters: IngestRawEvents must start before projectors so
  # domain events broadcast during boot are received by every subscriber.
  # Watcher starts last so its first read doesn't fire events before
  # downstream consumers are ready.
  defp maybe_add_watcher(children) do
    if Scry2.Config.get(:start_watcher) do
      # VersionCheck has already run (see maybe_add_version_check) — by
      # the time we get here, raw events have been retranslated and any
      # stale projector tables rebuilt, so projectors can start clean.
      # Stage 09: projectors subscribe first so they never miss an event.
      children ++
        Scry2.Events.ProjectorRegistry.all() ++
        [
          # Stage 08: ingestion worker translates raw events to domain events.
          Scry2.Events.IngestRawEvents,
          # Auto-triggers a collection refresh on log activity. Subscribes
          # to domain:events so it must start after projectors + ingester.
          Scry2.Collection.ActivityTrigger,
          # Stages 01–05: watcher reads Player.log and broadcasts raw events.
          Scry2.MtgaLogIngestion.Watcher
        ]
    else
      children
    end
  end
end
