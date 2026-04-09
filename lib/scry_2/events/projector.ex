defmodule Scry2.Events.Projector do
  @moduledoc """
  Shared behaviour and macros for domain event projectors (ADR-029).

  Projectors subscribe to `domain:events` for live updates and own
  their replay via cursor-based event queries. This module provides
  the boilerplate: GenServer setup, PubSub subscription, event dispatch,
  error handling, watermark tracking, and `rebuild!/0`.

  ## Usage

      defmodule Scry2.Mulligans.UpdateFromEvent do
        use Scry2.Events.Projector,
          claimed_slugs: ~w(mulligan_offered match_created),
          projection_tables: [Scry2.Mulligans.MulliganListing]

        defp project(%MulliganOffered{} = event) do
          # ... projection logic ...
          :ok
        end

        defp project(_event), do: :ok
      end

  The `use` macro provides:
  - `start_link/1`, `init/1` (subscribes to PubSub)
  - `handle_info/2` (dispatches claimed events to `project/1`, updates watermark)
  - `rebuild!/1` (resets watermark, truncates tables, replays from event store)
  - `catch_up!/1` (replays from watermark without truncating)
  - `claimed_slugs/0` (returns the list, useful for introspection)
  - `projector_name/0` (short name for logging and watermark keys)

  The module must define `defp project(event)` clauses for each
  claimed event type, plus a catch-all `defp project(_), do: :ok`.

  ## Progress callbacks

  `rebuild!/1` and `catch_up!/1` accept an `:on_progress` option — a
  2-arity function `(processed, total) -> any()`. Called after each
  batch (default 500 events). The total is counted upfront; if new
  events arrive during replay the progress bar caps at 100%.
  """

  defmacro __using__(opts) do
    claimed_slugs = Keyword.fetch!(opts, :claimed_slugs)
    projection_tables = Keyword.fetch!(opts, :projection_tables)

    quote do
      use GenServer

      require Scry2.Log, as: Log

      alias Scry2.Events
      alias Scry2.Topics

      @claimed_slugs unquote(claimed_slugs)
      @projection_tables unquote(projection_tables)
      @projector_name __MODULE__
                      |> Module.split()
                      |> Enum.take(-2)
                      |> Enum.join(".")

      def start_link(opts \\ []) do
        {name, opts} = Keyword.pop(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      @doc """
      Suspends live event processing. While suspended, `{:domain_event, ...}`
      messages are consumed from the mailbox but not projected. Used by
      `Events.reingest!/0` to avoid redundant live projections during retranslation
      (all projections are rebuilt from scratch by `replay_projections!/0` afterwards).
      """
      def suspend_live(name \\ __MODULE__) do
        GenServer.call(name, :suspend_live)
      end

      @doc "Resumes live event processing after `suspend_live/1`."
      def resume_live(name \\ __MODULE__) do
        GenServer.call(name, :resume_live)
      end

      @doc "Returns the event type slugs this projector handles."
      def claimed_slugs, do: @claimed_slugs

      @doc "Returns the short name used for logging and watermark keys."
      def projector_name, do: @projector_name

      @doc "Returns the total row count across all projection tables owned by this projector."
      def row_count do
        Enum.reduce(@projection_tables, 0, fn schema, acc ->
          acc + Scry2.Repo.aggregate(schema, :count)
        end)
      end

      @doc """
      Resets watermark, truncates all projection tables, and replays
      claimed events from the domain event store in id order.
      Cursor-based batching (ADR-029).

      Accepts `:on_progress` — a `(processed, total) -> any()` callback
      fired after each batch for real-time progress tracking.

      Call from any process — does not go through the GenServer.
      """
      def rebuild!(opts \\ []) do
        on_progress = Keyword.get(opts, :on_progress)
        total = Events.count_for_types(@claimed_slugs)

        Log.info(:ingester, "#{@projector_name}: rebuilding #{total} events from event store")

        Events.put_watermark!(@projector_name, 0)

        # Truncate projection tables (reverse order for FK safety)
        Enum.each(Enum.reverse(@projection_tables), &Scry2.Repo.delete_all/1)

        Events.replay_by_types(
          @claimed_slugs,
          fn event ->
            try do
              project(event)
            rescue
              error ->
                Log.warning(
                  :ingester,
                  "#{@projector_name} rebuild skip: #{inspect(error)}"
                )
            end
          end,
          on_batch: fn last_id, processed ->
            Events.put_watermark!(@projector_name, last_id)
            if on_progress, do: on_progress.(min(processed, total), total)
          end
        )

        # Final watermark for any remaining events
        max_id = Events.max_event_id_for_types(@claimed_slugs)
        if max_id > 0, do: Events.put_watermark!(@projector_name, max_id)
        if on_progress, do: on_progress.(total, total)

        Log.info(:ingester, "#{@projector_name}: rebuild complete")
        :ok
      end

      @doc """
      Resumes projection from the watermark without truncating tables.
      Replays only events after the last successfully processed id.

      Accepts `:on_progress` — same callback as `rebuild!/1`.
      """
      def catch_up!(opts \\ []) do
        on_progress = Keyword.get(opts, :on_progress)
        cursor = Events.get_watermark(@projector_name)
        total = Events.count_for_types_since(@claimed_slugs, cursor)

        Log.info(:ingester, "#{@projector_name}: catching up #{total} events from id=#{cursor}")

        Events.replay_by_types(
          @claimed_slugs,
          fn event ->
            try do
              project(event)
            rescue
              error ->
                Log.warning(
                  :ingester,
                  "#{@projector_name} catch-up skip: #{inspect(error)}"
                )
            end
          end,
          cursor: cursor,
          on_batch: fn last_id, processed ->
            Events.put_watermark!(@projector_name, last_id)
            if on_progress, do: on_progress.(min(processed, total), total)
          end
        )

        max_id = Events.max_event_id_for_types(@claimed_slugs)
        if max_id > 0, do: Events.put_watermark!(@projector_name, max_id)
        if on_progress, do: on_progress.(total, total)

        Log.info(:ingester, "#{@projector_name}: catch-up complete")
        :ok
      end

      @impl true
      def init(_opts) do
        Topics.subscribe(Topics.domain_events())
        {:ok, %{paused: false}}
      end

      @impl true
      def handle_call(:suspend_live, _from, state) do
        {:reply, :ok, Map.put(state, :paused, true)}
      end

      @impl true
      def handle_call(:resume_live, _from, state) do
        {:reply, :ok, Map.put(state, :paused, false)}
      end

      @impl true
      def handle_info({:domain_event, id, type_slug}, state)
          when type_slug in @claimed_slugs do
        unless Map.get(state, :paused, false) do
          try do
            event = Events.get!(id)
            project(event)
            Events.put_watermark!(@projector_name, id)
          rescue
            error ->
              Log.error(
                :ingester,
                "#{__MODULE__} failed on domain_event id=#{id} type=#{type_slug}: #{inspect(error)}"
              )
          end
        end

        {:noreply, state}
      end

      def handle_info({:domain_event, _id, _type_slug}, state), do: {:noreply, state}
      def handle_info(_other, state), do: {:noreply, state}
    end
  end
end
