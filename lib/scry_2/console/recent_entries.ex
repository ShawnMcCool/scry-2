defmodule Scry2.Console.RecentEntries do
  @moduledoc """
  A GenServer ring buffer that holds the most recent log entries in a
  capped list.

  This is the runtime state of the console. The buffer cap and filter are
  persisted to `Scry2.Settings` with a debounce to avoid excessive DB writes.

  All LiveViews and cross-context callers interact with the console through
  `Scry2.Console` — never with this module directly.

  ## Why a GenServer (and not ETS)

  Writes (log appends) and reads (LiveView snapshots + subscribers) have very
  different volumes in scry_2 — log volume is modest, and all writes must
  serialize through a single process anyway so the PubSub broadcast happens
  outside the hot logger-handler path. The handler casts here and returns;
  the buffer GenServer owns the broadcast.

  See `Scry2.Console.CaptureLogOutput` for the reentrancy guard on buffer's own
  failure logs.
  """
  use GenServer

  alias Scry2.Console.{Entry, Filter}
  alias Scry2.Settings
  alias Scry2.Topics

  @default_cap 2_000
  @min_cap 100
  @max_cap 50_000
  @persist_debounce_ms 2_000

  @filter_settings_key "console.filter"
  @buffer_size_settings_key "console.buffer_size"

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Fire-and-forget append. Safe to call when the buffer is not yet started."
  @spec append(Entry.t()) :: :ok
  def append(%Entry{} = entry), do: append(entry, __MODULE__)

  @doc "Explicit name variant for tests."
  @spec append(Entry.t(), atom()) :: :ok
  def append(%Entry{} = entry, name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:append, entry})
    end
  end

  @doc "Returns `%{entries: [...], cap: integer, filter: %Filter{}}` for the default buffer."
  @spec snapshot() :: map()
  def snapshot, do: snapshot(__MODULE__)

  @doc "Explicit name variant for tests."
  @spec snapshot(atom()) :: map()
  def snapshot(name) do
    GenServer.call(name, :snapshot)
  end

  @doc "Returns up to `n` entries newest-first. Pass `nil` for all entries."
  @spec recent(non_neg_integer() | nil) :: [Entry.t()]
  def recent(n \\ nil), do: recent(n, __MODULE__)

  @doc "Explicit name variant for tests."
  @spec recent(non_neg_integer() | nil, atom()) :: [Entry.t()]
  def recent(n, name) do
    GenServer.call(name, {:recent, n})
  end

  @doc "Clears all entries from the buffer."
  @spec clear() :: :ok
  def clear, do: clear(__MODULE__)

  @doc "Explicit name variant for tests."
  @spec clear(atom()) :: :ok
  def clear(name) do
    GenServer.call(name, :clear)
  end

  @doc "Maximum allowed buffer cap. Used by LiveViews to size the stream once."
  @spec max_cap() :: pos_integer()
  def max_cap, do: @max_cap

  @doc "Minimum allowed buffer cap."
  @spec min_cap() :: pos_integer()
  def min_cap, do: @min_cap

  @doc "Resizes the buffer cap. Must be between #{@min_cap} and #{@max_cap}."
  @spec resize(non_neg_integer()) :: :ok | {:error, String.t()}
  def resize(n), do: resize(n, __MODULE__)

  @doc "Explicit name variant for tests."
  @spec resize(non_neg_integer(), atom()) :: :ok | {:error, String.t()}
  def resize(n, name) when is_integer(n) do
    if n in @min_cap..@max_cap do
      GenServer.call(name, {:resize, n})
    else
      {:error, "cap must be between #{@min_cap} and #{@max_cap}, got #{n}"}
    end
  end

  @doc "Updates the active filter. Persists asynchronously."
  @spec put_filter(Filter.t()) :: :ok
  def put_filter(%Filter{} = filter), do: put_filter(filter, __MODULE__)

  @doc "Explicit name variant for tests."
  @spec put_filter(Filter.t(), atom()) :: :ok
  def put_filter(%Filter{} = filter, name) do
    GenServer.call(name, {:put_filter, filter})
  end

  @doc "Returns the current filter."
  @spec get_filter() :: Filter.t()
  def get_filter, do: get_filter(__MODULE__)

  @doc "Explicit name variant for tests."
  @spec get_filter(atom()) :: Filter.t()
  def get_filter(name) do
    GenServer.call(name, :get_filter)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    {settings_cap, filter} = load_settings()

    # opts[:cap] overrides the persisted cap — used in tests to set a small cap.
    # No floor/ceiling enforcement here; tests intentionally use values outside
    # the production range. The public resize/1 API enforces the range for callers.
    cap =
      case Keyword.get(opts, :cap) do
        override when is_integer(override) and override > 0 -> override
        _ -> settings_cap
      end

    state = %{
      entries: [],
      cap: cap,
      filter: filter,
      persist_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:append, entry}, state) do
    new_entries = Enum.take([entry | state.entries], state.cap)
    broadcast({:log_entry, entry})
    {:noreply, %{state | entries: new_entries}}
  end

  @impl true
  def handle_call({:recent, nil}, _from, state) do
    {:reply, state.entries, state}
  end

  def handle_call({:recent, n}, _from, state) when is_integer(n) do
    {:reply, Enum.take(state.entries, n), state}
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = %{entries: state.entries, cap: state.cap, filter: state.filter}
    {:reply, snapshot, state}
  end

  def handle_call(:clear, _from, state) do
    broadcast(:buffer_cleared)
    {:reply, :ok, %{state | entries: []}}
  end

  def handle_call({:resize, n}, _from, state) do
    new_entries = Enum.take(state.entries, n)
    new_state = %{state | cap: n, entries: new_entries}
    broadcast({:buffer_resized, n})
    new_state = schedule_persist(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:put_filter, filter}, _from, state) do
    new_state = %{state | filter: filter}
    broadcast({:filter_changed, filter})
    new_state = schedule_persist(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:get_filter, _from, state) do
    {:reply, state.filter, state}
  end

  @impl true
  def handle_info(:persist, state) do
    try do
      persist_to_settings(state)
    rescue
      error ->
        require Logger

        # Tag with scry2_log_source: :buffer so Console.CaptureLogOutput's reentrancy
        # guard drops this entry — otherwise a persist failure would
        # recursively self-document into the same buffer that just failed
        # to persist.
        Logger.warning(
          "Console.RecentEntries: failed to persist settings: #{inspect(error)}",
          scry2_log_source: :buffer
        )
    end

    {:noreply, %{state | persist_ref: nil}}
  end

  # --- Private helpers ---

  defp schedule_persist(state) do
    if state.persist_ref do
      Process.cancel_timer(state.persist_ref)
    end

    ref = Process.send_after(self(), :persist, @persist_debounce_ms)
    %{state | persist_ref: ref}
  end

  defp broadcast(message) do
    Topics.broadcast(Topics.console_logs(), message)
  end

  defp load_settings do
    try do
      cap =
        case Settings.get(@buffer_size_settings_key) do
          value when is_integer(value) ->
            if value in @min_cap..@max_cap, do: value, else: @default_cap

          _ ->
            @default_cap
        end

      filter =
        case Settings.get(@filter_settings_key) do
          value when is_map(value) -> Filter.from_persistable(value)
          _ -> Filter.new_with_defaults()
        end

      {cap, filter}
    rescue
      _ -> {@default_cap, Filter.new_with_defaults()}
    end
  end

  defp persist_to_settings(state) do
    Settings.put!(@buffer_size_settings_key, state.cap)
    Settings.put!(@filter_settings_key, Filter.to_persistable(state.filter))
  end
end
