defmodule Scry2.SelfUpdate.Updater do
  @moduledoc """
  GenServer that serializes self-update applies as a finite state machine:

      idle → preparing → downloading → extracting → handing_off → done
                                                                 ↘ failed

  Collaborators (Downloader, Stager, Handoff, current_version_fn,
  system_stop_fn) are injected via start options for test isolation per
  [ADR-009].

  **Public API:**
    - `apply_pending/1` — kick off an apply if a cached update exists.
      Returns `:ok | {:error, :already_running | :no_update_pending
      | :up_to_date | :ahead_of_release | :invalid_tag}`.
    - `status/1` — `%{phase: phase(), release: release | nil, error: term | nil}`.
  """

  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.SelfUpdate.ApplyLock
  alias Scry2.SelfUpdate.Downloader, as: DefaultDownloader
  alias Scry2.SelfUpdate.Handoff, as: DefaultHandoff
  alias Scry2.SelfUpdate.Stager, as: DefaultStager
  alias Scry2.SelfUpdate.UpdateChecker
  alias Scry2.Topics
  alias Scry2.Version

  @type phase ::
          :idle | :preparing | :downloading | :extracting | :handing_off | :done | :failed

  @cancelable_phases [:preparing, :downloading, :extracting]

  # --- Public API ---

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec apply_pending(GenServer.server()) ::
          :ok
          | {:error,
             :already_running
             | :no_update_pending
             | :up_to_date
             | :ahead_of_release
             | :invalid_tag}
  def apply_pending(server \\ __MODULE__) do
    GenServer.call(server, :apply_pending, 30_000)
  end

  @spec status(GenServer.server()) :: %{phase: phase(), release: map() | nil, error: term() | nil}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Cancels an in-flight apply if it's still before the point of no
  return. The detached installer spawn at `:handing_off` is uncancelable
  — once the external process is running there's nothing to kill.

  Returns:
    * `:ok` when a cancelable apply was running and has been stopped.
    * `{:error, :not_running}` when nothing is in flight.
    * `{:error, :past_point_of_no_return}` once `:handing_off` has fired.
  """
  @spec cancel(GenServer.server()) ::
          :ok | {:error, :not_running | :past_point_of_no_return}
  def cancel(server \\ __MODULE__), do: GenServer.call(server, :cancel)

  # --- Callbacks ---

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      phase: :idle,
      release: nil,
      error: nil,
      lock_path: Keyword.fetch!(opts, :lock_path),
      staging_root: Keyword.fetch!(opts, :staging_root),
      downloader: Keyword.get(opts, :downloader, &DefaultDownloader.run/2),
      stager: Keyword.get(opts, :stager, &default_extract/2),
      handoff: Keyword.get(opts, :handoff, &DefaultHandoff.spawn_detached/2),
      current_version_fn: Keyword.get(opts, :current_version_fn, &Version.current/0),
      system_stop_fn: Keyword.get(opts, :system_stop_fn, &System.stop/1),
      task_pid: nil,
      staging_dir: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, %{phase: state.phase, release: state.release, error: state.error}, state}
  end

  def handle_call(:apply_pending, _from, %{phase: phase} = state)
      when phase not in [:idle, :done, :failed] do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call(:cancel, _from, %{task_pid: nil} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:cancel, _from, %{phase: phase, task_pid: task_pid} = state)
      when phase in @cancelable_phases and is_pid(task_pid) do
    # Clear task_pid first so the subsequent {:EXIT, ...} message from
    # the now-doomed task falls through to the catch-all clause instead
    # of being re-classified as :failed.
    state = %{state | task_pid: nil}
    Process.exit(task_pid, :kill)

    _ = ApplyLock.release(state.lock_path)
    _ = rm_staging(state.staging_dir)
    Topics.broadcast(Topics.updates_progress(), {:apply_cancelled})
    Log.info(:system, "self-update apply cancelled from phase #{phase}")

    {:reply, :ok, %{state | phase: :idle, release: nil, error: nil, staging_dir: nil}}
  end

  def handle_call(:cancel, _from, state) do
    {:reply, {:error, :past_point_of_no_return}, state}
  end

  def handle_call(:apply_pending, _from, state) do
    case UpdateChecker.cached_latest_release() do
      :none ->
        {:reply, {:error, :no_update_pending}, state}

      {:ok, release} ->
        case UpdateChecker.validate_tag(release.tag) do
          {:error, _} ->
            {:reply, {:error, :invalid_tag}, state}

          {:ok, _tag} ->
            local = state.current_version_fn.()

            case UpdateChecker.classify(release.version, local) do
              :update_available -> {:reply, :ok, start_apply(release, state)}
              :up_to_date -> {:reply, {:error, :up_to_date}, state}
              :ahead_of_release -> {:reply, {:error, :ahead_of_release}, state}
              :invalid -> {:reply, {:error, :invalid_tag}, state}
            end
        end
    end
  end

  @impl GenServer
  def handle_info({:phase, :downloading}, state) do
    broadcast_phase(:downloading)
    {:noreply, %{state | phase: :downloading}}
  end

  def handle_info({:phase, :extracting}, state) do
    broadcast_phase(:extracting)
    {:noreply, %{state | phase: :extracting}}
  end

  def handle_info({:phase, :handing_off}, state) do
    broadcast_phase(:handing_off)
    _ = ApplyLock.update_phase(state.lock_path, "handing_off")
    {:noreply, %{state | phase: :handing_off}}
  end

  def handle_info({:apply_failed, reason}, state) do
    _ = ApplyLock.release(state.lock_path)
    broadcast_phase(:failed, reason)
    Log.error(:system, "self-update apply failed: #{inspect(reason)}")
    {:noreply, %{state | phase: :failed, error: reason, task_pid: nil}}
  end

  def handle_info({:apply_succeeded}, state) do
    state.system_stop_fn.(0)
    broadcast_phase(:done)
    {:noreply, %{state | phase: :done, task_pid: nil}}
  end

  # Trap-exit messages for the linked task. Normal exit after a terminal
  # message (:apply_failed / :apply_succeeded) is a no-op. Abnormal exit
  # before a terminal message transitions to :failed and releases the lock.
  def handle_info({:EXIT, pid, :normal}, %{task_pid: pid} = state) do
    {:noreply, %{state | task_pid: nil}}
  end

  def handle_info({:EXIT, pid, reason}, %{task_pid: pid, phase: phase} = state)
      when phase not in [:done, :failed, :idle] do
    _ = ApplyLock.release(state.lock_path)
    broadcast_phase(:failed, reason)
    Log.error(:system, "self-update task crashed: #{inspect(reason)}")
    {:noreply, %{state | phase: :failed, error: reason, task_pid: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  # --- Private ---

  defp start_apply(release, state) do
    broadcast_phase(:preparing)
    _ = ApplyLock.acquire(state.lock_path, version: release.version)

    parent = self()

    staging_dir = Path.join(state.staging_root, "#{release.version}-#{random_suffix()}")
    File.mkdir_p!(staging_dir)

    archive_filename = UpdateChecker.archive_name(release.tag, :os.type())
    archive_url = UpdateChecker.download_url(release.tag, archive_filename)

    sha_url =
      UpdateChecker.download_url(
        release.tag,
        UpdateChecker.sha256sums_name(release.tag, :os.type())
      )

    downloader = state.downloader
    stager = state.stager
    handoff = state.handoff

    progress_fn = fn bytes, total ->
      if is_integer(total) and total > 0 do
        pct = min(div(bytes * 100, total), 100)
        Topics.broadcast(Topics.updates_progress(), {:download_progress, pct})
      end
    end

    task_pid =
      spawn_link(fn ->
        send(parent, {:phase, :downloading})

        case downloader.(
               %{
                 archive_url: archive_url,
                 archive_filename: archive_filename,
                 sha256sums_url: sha_url,
                 dest_dir: staging_dir
               },
               progress_fn: progress_fn
             ) do
          {:ok, %{archive_path: archive_path}} ->
            send(parent, {:phase, :extracting})

            case stager.(archive_path, staging_dir) do
              {:ok, staged_root} ->
                send(parent, {:phase, :handing_off})

                case handoff.(
                       %{staged_root: staged_root, archive_filename: archive_filename},
                       []
                     ) do
                  :ok -> send(parent, {:apply_succeeded})
                  {:error, reason} -> send(parent, {:apply_failed, reason})
                end

              {:error, reason} ->
                send(parent, {:apply_failed, reason})
            end

          {:error, reason} ->
            send(parent, {:apply_failed, reason})
        end
      end)

    %{
      state
      | phase: :preparing,
        release: release,
        error: nil,
        task_pid: task_pid,
        staging_dir: staging_dir
    }
  end

  defp rm_staging(nil), do: :ok

  defp rm_staging(path) when is_binary(path) do
    _ = File.rm_rf(path)
    :ok
  end

  defp broadcast_phase(phase),
    do: Topics.broadcast(Topics.updates_progress(), {:phase, phase})

  defp broadcast_phase(phase, reason),
    do: Topics.broadcast(Topics.updates_progress(), {:phase, phase, reason})

  defp random_suffix,
    do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  defp default_extract(archive, dest) do
    cond do
      String.ends_with?(archive, ".tar.gz") ->
        DefaultStager.extract_tar(archive, dest, required: required_files(archive))

      String.ends_with?(archive, ".zip") ->
        DefaultStager.extract_zip(archive, dest, required: required_files(archive))

      # Burn bootstrappers (.exe / .msi) are single-file installers — there is
      # nothing to extract or validate, the spawned bootstrapper handles its
      # own integrity.
      String.ends_with?(archive, ".exe") ->
        {:ok, Path.dirname(archive)}

      true ->
        {:error, {:unknown_archive, archive}}
    end
  end

  # Members the release archive must contain for handoff to be safe. A
  # truncated or malformed release fails fast at the Stager rather than
  # spawning an installer that can't migrate.
  #
  # `scripts/release` copies `scripts/install-linux` / `install-macos`
  # into the package as plain `install` (and the Windows path as
  # `install.bat`). The Stager strips the archive's single top-level
  # wrapper directory before checking, so paths here are relative to
  # the release root, not to `dest_dir/extracted`.
  defp required_files(archive) do
    cond do
      String.contains?(archive, "-linux-") -> ["install", "bin/scry_2"]
      String.contains?(archive, "-macos-") -> ["install", "bin/scry_2"]
      String.contains?(archive, "-windows-") -> ["install.bat", "bin/scry_2.bat"]
      true -> []
    end
  end
end
