defmodule Scry2.Uplink.Sender do
  @moduledoc """
  Drains the unsent domain-event batch (`Scry2.Uplink`) on an interval and
  ships it through an injected `Scry2.Uplink.Transport` implementation
  (client/server split, ADR-042 Phase 2).

  The uplink cursor is advanced only after a successful send, so a failed or
  offline transport simply retries the same batch on the next tick — the
  server upserts by `upload_key`, making re-sends idempotent.

  Start options:

    * `:transport` (required) — a module implementing `Scry2.Uplink.Transport`.
    * `:config` — an opaque map passed to `send_batch/2` (e.g. server url + token).
    * `:flush_interval_ms` — timer period between automatic flushes (default 5000).
    * `:batch_limit` — max events per flush (default 500).

  Not started by the application supervisor yet — Phase 2b-2 wires it up behind
  config once the server exists.
  """
  use GenServer

  alias Scry2.Uplink

  @default_flush_interval_ms 5_000
  @default_batch_limit 500

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs one flush cycle synchronously and returns the outcome:
  `:ok` (nothing to send), `{:sent, count}` (batch accepted, cursor advanced),
  or `{:error, reason}` (transport failed, cursor unchanged). Public API for
  on-demand flushing and tests.
  """
  @spec flush(GenServer.server()) :: :ok | {:sent, non_neg_integer()} | {:error, term()}
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @impl true
  def init(opts) do
    state = %{
      transport: Keyword.fetch!(opts, :transport),
      config: Keyword.get(opts, :config, %{}),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms),
      batch_limit: Keyword.get(opts, :batch_limit, @default_batch_limit)
    }

    schedule_flush(state.flush_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, do_flush(state), state}
  end

  @impl true
  def handle_info(:flush_tick, state) do
    do_flush(state)
    schedule_flush(state.flush_interval_ms)
    {:noreply, state}
  end

  defp do_flush(state) do
    {batch, new_cursor} = Uplink.unsent_batch(state.batch_limit)

    case batch do
      [] ->
        :ok

      _ ->
        case state.transport.send_batch(state.config, batch) do
          :ok ->
            Uplink.mark_sent!(new_cursor)
            {:sent, length(batch)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp schedule_flush(interval_ms), do: Process.send_after(self(), :flush_tick, interval_ms)
end
