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
  - `rebuild!/0` (resets watermark, truncates tables, replays from event store)
  - `catch_up!/0` (replays from watermark without truncating)
  - `claimed_slugs/0` (returns the list, useful for introspection)
  - `projector_name/0` (short name for logging and watermark keys)

  The module must define `defp project(event)` clauses for each
  claimed event type, plus a catch-all `defp project(_), do: :ok`.
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

      @doc "Returns the event type slugs this projector handles."
      def claimed_slugs, do: @claimed_slugs

      @doc "Returns the short name used for logging and watermark keys."
      def projector_name, do: @projector_name

      @doc """
      Resets watermark, truncates all projection tables, and replays
      claimed events from the domain event store in id order.
      Cursor-based batching (ADR-029).

      Call from any process — does not go through the GenServer.
      """
      def rebuild! do
        Log.info(:ingester, "#{@projector_name}: rebuilding from event store")

        Events.put_watermark!(@projector_name, 0)

        # Truncate projection tables (reverse order for FK safety)
        Enum.each(Enum.reverse(@projection_tables), &Scry2.Repo.delete_all/1)

        Events.replay_by_types(@claimed_slugs, fn event ->
          try do
            project(event)
            event_id = Map.get(event, :id)
            if event_id, do: Events.put_watermark!(@projector_name, event_id)
          rescue
            error ->
              Log.warning(
                :ingester,
                "#{@projector_name} rebuild skip: #{inspect(error)}"
              )
          end
        end)

        Log.info(:ingester, "#{@projector_name}: rebuild complete")
        :ok
      end

      @doc """
      Resumes projection from the watermark without truncating tables.
      Replays only events after the last successfully processed id.
      """
      def catch_up! do
        cursor = Events.get_watermark(@projector_name)
        Log.info(:ingester, "#{@projector_name}: catching up from event id=#{cursor}")

        Events.replay_by_types(
          @claimed_slugs,
          fn event ->
            try do
              project(event)
              event_id = Map.get(event, :id)
              if event_id, do: Events.put_watermark!(@projector_name, event_id)
            rescue
              error ->
                Log.warning(
                  :ingester,
                  "#{@projector_name} catch-up skip: #{inspect(error)}"
                )
            end
          end,
          cursor: cursor
        )

        Log.info(:ingester, "#{@projector_name}: catch-up complete")
        :ok
      end

      @impl true
      def init(_opts) do
        Topics.subscribe(Topics.domain_events())
        {:ok, %{}}
      end

      @impl true
      def handle_info({:domain_event, id, type_slug}, state)
          when type_slug in @claimed_slugs do
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

        {:noreply, state}
      end

      def handle_info({:domain_event, _id, _type_slug}, state), do: {:noreply, state}
      def handle_info(_other, state), do: {:noreply, state}
    end
  end
end
