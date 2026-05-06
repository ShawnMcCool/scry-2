defmodule Scry2.MtgaEvents do
  @moduledoc """
  Active-events reader — exposes the player's current MTGA event
  entries (Premier Draft, Quick Draft, Standard Ranked, etc.) by
  walking `PAPA._instance.EventManager` in the live MTGA process.

  This is **not** the event-sourcing context (`Scry2.Events`) — that
  one owns the typed domain event log. The name "MTGA events" follows
  MTGA's own UI vocabulary, where a "queue" / "play mode" entry is
  called an *event*. The two namespaces are independent.

  Source data lives entirely in the MTGA process's heap; nothing is
  persisted. Calling `read_active_events/0` is the only way to refresh —
  there is no GenServer cache (the underlying walker has its own
  per-pid discovery cache; a second call within seconds is cheap).

  Wins/losses, current state, and format come straight from
  `ClientPlayerCourseV3` / `EventInfoV3` — see
  `mtga-duress/experiments/spikes/spike21_active_events/FINDING.md`
  and the `mono-memory-reader` skill's Chain 3 section.
  """

  alias Scry2.Collection.Reader.Discovery
  alias Scry2.MtgaMemory

  @doc """
  Read the player's active MTGA event entries.

  Returns:
    * `{:ok, records}` — a list of `t:Scry2.MtgaMemory.event_record/0`
      maps for entries the player is **actively engaged** with
      (`current_event_state != 0`). Available-but-untouched entries
      are filtered out — they're just "events you could enter," not
      something to surface.
    * `{:ok, []}` — MTGA is running but the engaged set is empty
      (rare in practice; usually at least Play / Ladder are engaged
      because they're "standing").
    * `{:error, :mtga_not_running}` — no MTGA process found.
    * `{:error, reason}` — walker failure (mono dll missing, PAPA
      not yet loaded, EventManager anchor null pre-login, etc.).

  The `mem` keyword is for tests — pass an alternate
  `Scry2.MtgaMemory` impl. Defaults to `Scry2.MtgaMemory.impl/0`.
  """
  @spec read_active_events(keyword()) ::
          {:ok, [MtgaMemory.event_record()]} | {:error, atom()}
  def read_active_events(opts \\ []) do
    mem = Keyword.get(opts, :mem, MtgaMemory.impl())

    with {:ok, pid} <- Discovery.find_mtga(mem),
         {:ok, list} <- mem.walk_events(pid) do
      records =
        case list do
          nil -> []
          %{records: records} -> Enum.filter(records, &actively_engaged?/1)
        end

      {:ok, records}
    end
  end

  @doc "True when the player is opted in or in the standing pool."
  @spec actively_engaged?(MtgaMemory.event_record()) :: boolean()
  def actively_engaged?(%{current_event_state: state}), do: state != 0
end
