defmodule Scry2.MtgaLogIngestion.Watcher do
  @moduledoc """
  GenServer that tails MTGA's `Player.log` and persists raw events.

  ## Lifecycle

  1. `init/1` is intentionally lightweight — it stores options and
     schedules work via `handle_continue/2` so the supervisor doesn't
     block on file I/O at startup.
  2. `handle_continue(:bootstrap, _)` resolves the log path, restores
     the byte cursor from `mtga_logs_cursor`, and subscribes to
     filesystem events via `FileSystem`.
  3. On `:modified` events we read the new byte range, run it through
     `ExtractEventsFromLog`, persist each event via `Scry2.MtgaLogIngestion.insert_event!/1`,
     and advance the cursor.
  4. On rotation (size shrinks or inode changes) we reset to offset 0.

  ## Failure modes

  * **No log file found.** We broadcast `{:status, :path_not_found}` to
    `mtga_logs:status` and stay alive waiting for a settings update. We
    don't crash — the user may start MTGA later.
  * **Permission / I/O errors.** Logged, status broadcast, then retry
    on the next tick.

  See ADR-012 (durable process design) and ADR-015 (raw event replay).
  """
  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.MtgaLogIngestion
  alias Scry2.MtgaLogIngestion.{ExtractEventsFromLog, LocateLogFile, ReadNewBytes}
  alias Scry2.Settings
  alias Scry2.Topics

  @default_poll_interval 500
  @min_poll_interval 100
  @max_poll_interval 10_000
  @poll_interval_setting_key "mtga_logs_poll_interval_ms"

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current watcher state for dashboard/settings UI."
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{state: :not_running}
  end

  @doc """
  Forces a re-resolution of the log path — used after the user updates
  the path in the settings LiveView.
  """
  def reload_path do
    GenServer.cast(__MODULE__, :reload_path)
  end

  @doc """
  Clamps a `poll_interval_ms` value into the valid range
  (#{@min_poll_interval}–#{@max_poll_interval} ms), returning the
  default (#{@default_poll_interval} ms) for `nil`, empty strings, or
  non-integer input.

  Exposed as a public function so it can be unit-tested without the
  GenServer. Called internally during `init/1` and when Settings
  broadcasts a `poll_interval_ms` change.
  """
  @spec clamp_interval(term()) :: pos_integer()
  def clamp_interval(value) when is_integer(value) do
    value |> max(@min_poll_interval) |> min(@max_poll_interval)
  end

  def clamp_interval(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> clamp_interval(int)
      _ -> @default_poll_interval
    end
  end

  def clamp_interval(_), do: @default_poll_interval

  # ── Callbacks ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Topics.subscribe(Topics.settings_updates())

    state = %{
      path: nil,
      offset: 0,
      log_epoch: 0,
      inode: nil,
      status: :starting,
      fs_pid: nil,
      poll_interval: resolve_poll_interval(opts),
      drain_timer: nil,
      override_path: Keyword.get(opts, :path)
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  defp resolve_poll_interval(opts) do
    case Keyword.fetch(opts, :poll_interval) do
      {:ok, value} ->
        clamp_interval(value)

      :error ->
        Settings.get_or_config(@poll_interval_setting_key, :mtga_logs_poll_interval_ms)
        |> clamp_interval()
    end
  rescue
    # Settings table may not be available in very early boot or in unit
    # tests that don't set up the sandbox. Fall back gracefully.
    _ -> @default_poll_interval
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    case resolve_path(state) do
      {:ok, path} ->
        state = start_watching(state, path)
        {:noreply, state}

      {:error, :not_found} ->
        Log.warning(:watcher, "Player.log not found — watcher idle until settings update")
        broadcast_status(:path_not_found)
        {:noreply, %{state | status: :path_not_found}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    payload = %{
      state: state.status,
      path: state.path,
      offset: state.offset
    }

    {:reply, payload, state}
  end

  @impl true
  def handle_cast(:reload_path, state) do
    state = stop_fs(state)

    case resolve_path(%{state | override_path: nil}) do
      {:ok, path} ->
        {:noreply, start_watching(state, path)}

      {:error, :not_found} ->
        broadcast_status(:path_not_found)
        {:noreply, %{state | status: :path_not_found, path: nil}}
    end
  end

  @impl true
  def handle_info({:file_event, _fs_pid, {path, events}}, %{path: watched_path} = state)
      when path == watched_path do
    cond do
      :modified in events or :created in events ->
        {:noreply, schedule_drain(state)}

      :deleted in events or :renamed in events ->
        broadcast_status(:path_missing)
        {:noreply, %{state | status: :path_missing}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _fs_pid, :stop}, state) do
    {:noreply, stop_fs(state)}
  end

  @impl true
  def handle_info(:drain, state) do
    {:noreply, %{drain_file(state) | drain_timer: nil}}
  end

  @impl true
  def handle_info({:setting_changed, @poll_interval_setting_key}, state) do
    new_interval =
      Settings.get_or_config(@poll_interval_setting_key, :mtga_logs_poll_interval_ms)
      |> clamp_interval()

    if new_interval != state.poll_interval do
      Log.info(:watcher, "poll_interval_ms updated: #{state.poll_interval} → #{new_interval}")
    end

    {:noreply, %{state | poll_interval: new_interval}}
  end

  @impl true
  def handle_info({:setting_changed, _key}, state), do: {:noreply, state}

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  # ── Internals ───────────────────────────────────────────────────────────

  defp resolve_path(%{override_path: path}) when is_binary(path) do
    if File.regular?(path), do: {:ok, path}, else: {:error, :not_found}
  end

  defp resolve_path(_state), do: LocateLogFile.resolve()

  defp start_watching(state, path) do
    cursor = MtgaLogIngestion.get_cursor(path)
    {offset, inode, log_epoch} = cursor_initial(cursor)

    {:ok, fs_pid} = FileSystem.start_link(dirs: [Path.dirname(path)])
    FileSystem.subscribe(fs_pid)

    state =
      %{
        state
        | path: path,
          offset: offset,
          log_epoch: log_epoch,
          inode: inode,
          fs_pid: fs_pid,
          status: :running
      }

    broadcast_status(:running)
    drain_file(state)
  end

  defp cursor_initial(nil), do: {0, nil, 0}

  defp cursor_initial(%{byte_offset: offset, inode: inode, log_epoch: log_epoch}),
    do: {offset, inode, log_epoch || 0}

  defp stop_fs(%{fs_pid: nil} = state), do: state

  defp stop_fs(%{fs_pid: fs_pid} = state) do
    if Process.alive?(fs_pid), do: Process.exit(fs_pid, :normal)
    %{state | fs_pid: nil}
  end

  # Debounce drains: if a drain is already scheduled, let it fire; we
  # coalesce rapid bursts of :modified events into a single drain pass.
  defp schedule_drain(%{drain_timer: timer} = state) when is_reference(timer), do: state

  defp schedule_drain(%{poll_interval: interval} = state) do
    timer = Process.send_after(self(), :drain, interval)
    %{state | drain_timer: timer}
  end

  defp drain_file(%{path: path, offset: offset, log_epoch: log_epoch} = state)
       when is_binary(path) do
    case ReadNewBytes.read_since(path, offset) do
      {:ok, %{bytes: "", new_offset: new_offset, inode: inode}} ->
        %{state | offset: new_offset, inode: inode}

      {:ok, %{bytes: bytes, new_offset: new_offset, rotated?: rotated, inode: inode}} ->
        base_offset = if rotated, do: 0, else: offset
        new_epoch = if rotated, do: log_epoch + 1, else: log_epoch

        if rotated do
          Log.info(:watcher, "log rotation detected — advancing to epoch #{new_epoch}")
        end

        {events, warnings} = ExtractEventsFromLog.parse_chunk(bytes, path, base_offset)

        for warning <- warnings do
          Log.warning(
            :parser,
            "#{warning.category} at offset #{warning.file_offset}: #{warning.detail}"
          )
        end

        events_attrs =
          Enum.map(events, fn event ->
            %{
              event_type: event.type,
              mtga_timestamp: event.mtga_timestamp,
              file_offset: event.file_offset,
              source_file: event.source_file,
              log_epoch: new_epoch,
              raw_json: event.raw_json
            }
          end)

        Scry2.Repo.transaction(fn ->
          MtgaLogIngestion.insert_events!(events_attrs)

          MtgaLogIngestion.put_cursor!(%{
            file_path: path,
            byte_offset: new_offset,
            log_epoch: new_epoch,
            inode: inode
          })
        end)

        %{state | offset: new_offset, log_epoch: new_epoch, inode: inode}

      {:error, reason} ->
        Log.warning(:watcher, "drain_file error: #{inspect(reason)}")
        state
    end
  end

  defp drain_file(state), do: state

  defp broadcast_status(status) do
    Topics.broadcast(Topics.mtga_logs_status(), {:status, status})
  end
end
