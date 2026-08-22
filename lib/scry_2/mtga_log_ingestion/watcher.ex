defmodule Scry2.MtgaLogIngestion.Watcher do
  @moduledoc """
  GenServer that tails MTGA's `Player.log` and persists raw events.

  The tail is driven by a plain poll timer — every `poll_interval` ms
  (default 500) we `stat` the file and read any new bytes. No filesystem
  event subsystem is involved: inotify (via the `file_system` package)
  required the `inotify-tools` system package on Linux and crashed the
  whole application when it was absent (GitHub issue #1), while buying
  no latency — drains were already debounced to `poll_interval`. A stat
  on an unchanged file is a no-op cheap enough to run forever.

  ## Lifecycle

  1. `init/1` is intentionally lightweight — it stores options and
     schedules work via `handle_continue/2` so the supervisor doesn't
     block on file I/O at startup.
  2. `handle_continue(:bootstrap, _)` runs the first poll tick: resolve
     the log path, restore the byte cursor from `mtga_logs_cursor`, and
     drain. Every subsequent tick re-drains from the current offset.
  3. On each drain we read the new byte range, run it through
     `ExtractEventsFromLog`, persist each event via `Scry2.MtgaLogIngestion.insert_event!/1`,
     and advance the cursor.
  4. On rotation (size shrinks) we reset to offset 0 and advance the
     log epoch.

  ## Failure modes

  The watcher never crashes on environmental problems — it degrades to
  a status and keeps polling until the world improves:

  * **No log file found** (`:path_not_found`): the path never resolved.
    Each tick retries resolution, so starting MTGA later is picked up
    automatically.
  * **Tailed file disappeared** (`:path_missing`): the file we were
    tailing was deleted or renamed. Each tick re-stats the same path;
    when MTGA recreates it we resume as a rotation.
  * **Permission / I/O errors**: logged, then retried on the next tick.

  Status transitions are broadcast to `mtga_logs:status` (only on
  change, never per tick).

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
      poll_interval: resolve_poll_interval(opts),
      poll_timer: nil,
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
    {:noreply, state |> poll_tick() |> schedule_poll()}
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
    state = %{state | path: nil, offset: 0, log_epoch: 0, inode: nil, override_path: nil}
    {:noreply, state |> poll_tick() |> schedule_poll()}
  end

  @impl true
  def handle_info(:poll, state) do
    state = %{state | poll_timer: nil}
    {:noreply, state |> poll_tick() |> schedule_poll()}
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

  defp schedule_poll(%{poll_timer: nil, poll_interval: interval} = state) do
    %{state | poll_timer: Process.send_after(self(), :poll, interval)}
  end

  defp schedule_poll(state), do: state

  # No path yet — retry resolution until Player.log shows up.
  defp poll_tick(%{path: nil} = state) do
    case resolve_path(state) do
      {:ok, path} -> state |> begin_tailing(path) |> poll_tick()
      {:error, :not_found} -> set_status(state, :path_not_found)
    end
  end

  defp poll_tick(state) do
    case drain_file(state) do
      {:ok, state} -> set_status(state, :running)
      {:error, :enoent, state} -> set_status(state, :path_missing)
      {:error, _reason, state} -> state
    end
  end

  defp resolve_path(%{override_path: path}) when is_binary(path) do
    if File.regular?(path), do: {:ok, path}, else: {:error, :not_found}
  end

  defp resolve_path(_state), do: LocateLogFile.resolve()

  defp begin_tailing(state, path) do
    cursor = MtgaLogIngestion.get_cursor(path)
    {offset, inode, log_epoch} = cursor_initial(cursor)

    %{state | path: path, offset: offset, log_epoch: log_epoch, inode: inode}
  end

  defp cursor_initial(nil), do: {0, nil, 0}

  defp cursor_initial(%{byte_offset: offset, inode: inode, log_epoch: log_epoch}),
    do: {offset, inode, log_epoch || 0}

  defp drain_file(%{path: path, offset: offset, log_epoch: log_epoch} = state) do
    case ReadNewBytes.read_since(path, offset) do
      {:ok, %{bytes: "", new_offset: new_offset, inode: inode}} ->
        {:ok, %{state | offset: new_offset, inode: inode}}

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
          Enum.map(events, fn raw_event ->
            %{
              event_type: raw_event.type,
              mtga_timestamp: raw_event.mtga_timestamp,
              file_offset: raw_event.file_offset,
              source_file: raw_event.source_file,
              log_epoch: new_epoch,
              raw_json: raw_event.raw_json
            }
          end)

        {:ok, inserted_count} =
          Scry2.Repo.transaction(fn ->
            {count, _} = MtgaLogIngestion.insert_events!(events_attrs)

            MtgaLogIngestion.put_cursor!(%{
              file_path: path,
              byte_offset: new_offset,
              log_epoch: new_epoch,
              inode: inode
            })

            count
          end)

        # Broadcast after the txn commits so PubSub fan-out doesn't hold
        # the SQLite write lock. `insert_events!/1` skips the broadcast
        # when invoked inside a transaction.
        MtgaLogIngestion.broadcast_inserted(inserted_count)

        {:ok, %{state | offset: new_offset, log_epoch: new_epoch, inode: inode}}

      {:error, :enoent} ->
        {:error, :enoent, state}

      {:error, reason} ->
        Log.warning(:watcher, "drain_file error: #{inspect(reason)}")
        {:error, reason, state}
    end
  end

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, new_status) do
    log_transition(new_status, state)
    broadcast_status(new_status)
    %{state | status: new_status}
  end

  defp log_transition(:path_not_found, _state),
    do: Log.warning(:watcher, "Player.log not found — polling until it appears")

  defp log_transition(:path_missing, %{path: path}),
    do: Log.warning(:watcher, "#{path} disappeared — polling until it reappears")

  defp log_transition(:running, %{path: path}),
    do: Log.info(:watcher, "tailing #{path}")

  defp broadcast_status(status) do
    Topics.broadcast(Topics.mtga_logs_status(), {:status, status})
  end
end
