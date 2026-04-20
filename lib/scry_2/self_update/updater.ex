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
      task_pid: nil
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
               []
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

    %{state | phase: :preparing, release: release, error: nil, task_pid: task_pid}
  end

  defp broadcast_phase(phase),
    do: Topics.broadcast(Topics.updates_progress(), {:phase, phase})

  defp broadcast_phase(phase, reason),
    do: Topics.broadcast(Topics.updates_progress(), {:phase, phase, reason})

  defp random_suffix,
    do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  defp default_extract(archive, dest) do
    cond do
      String.ends_with?(archive, ".tar.gz") -> DefaultStager.extract_tar(archive, dest)
      String.ends_with?(archive, ".zip") -> DefaultStager.extract_zip(archive, dest)
      String.ends_with?(archive, ".exe") -> {:ok, Path.dirname(archive)}
      true -> {:error, {:unknown_archive, archive}}
    end
  end
end
