defmodule Scry2.Events.Projector do
  @moduledoc """
  Shared behaviour and macros for domain event projectors (ADR-029).

  Projectors subscribe to `domain:events` for live updates and own
  their replay via cursor-based event queries. This module provides
  the boilerplate: GenServer setup, PubSub subscription, event dispatch,
  error handling, watermark tracking, and rebuild/catch-up.

  ## Usage

      defmodule Scry2.Mulligans.MulliganProjection do
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
  - `start_link/1`, `init/1` (subscribes to `domain:events` and `domain:control`)
  - `handle_info/2` (dispatches claimed events to `project/1`, updates watermark)
  - `handle_info(:full_rebuild)` (triggered after reingest — see below)
  - `rebuild!/1` (explicit standalone rebuild — domain events immutable)
  - `catch_up!/1` (replays from watermark without truncating)
  - `claimed_slugs/0` (returns the list, useful for introspection)
  - `projector_name/0` (short name for logging and watermark keys)

  The module must define `defp project(event)` clauses for each
  claimed event type, plus a catch-all `defp project(_), do: :ok`.

  ## Two rebuild modes

  These are fundamentally different and must not be conflated:

  | Mode | When | Watermark |
  |------|------|-----------|
  | `:full_rebuild` via `domain:control` | After reingest — domain events wiped and regenerated | **Stale — reset to 0** |
  | `rebuild!/1` / `catch_up!/1` | Standalone explicit rebuild — domain events immutable | **Valid cursor** |

  When reingest completes, `Scry2.Operations` broadcasts `:full_rebuild` on
  `domain:control`. Each projector's GenServer picks this up from its mailbox.
  Because BEAM processes are single-threaded, any `{:domain_event, ...}` messages
  that arrive from the Watcher while `:full_rebuild` is processing simply queue in
  the mailbox and are handled normally after the rebuild returns — zero message loss
  with no extra buffering or state flags.

  ## Progress callbacks

  `rebuild!/1` and `catch_up!/1` accept an `:on_progress` option — a
  2-arity function `(processed, total) -> any()`. Called after each
  batch (default 1000 events). The total is counted upfront; if new
  events arrive during replay the progress bar caps at 100%.
  """

  defmacro __using__(opts) do
    claimed_slugs = Keyword.fetch!(opts, :claimed_slugs)
    projection_tables = Keyword.fetch!(opts, :projection_tables)
    caller_file = __CALLER__.file

    quote do
      use GenServer

      require Scry2.Log, as: Log

      alias Scry2.Events
      alias Scry2.Topics

      @external_resource unquote(caller_file)

      @claimed_slugs unquote(claimed_slugs)
      @projection_tables unquote(projection_tables)
      @projector_name __MODULE__
                      |> Module.split()
                      |> Enum.take(-2)
                      |> Enum.join(".")

      @content_hash (
                      {:ok, ast} =
                        unquote(caller_file) |> File.read!() |> Code.string_to_quoted()

                      :erlang.phash2(ast) |> Integer.to_string()
                    )

      @doc "Returns the compile-time AST hash of this projector's source."
      def content_hash, do: @content_hash

      def start_link(opts \\ []) do
        {name, opts} = Keyword.pop(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
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

        # Catch all three exit kinds (:error, :exit, :throw) so replay continues past
        # any single bad event — connection-checkout timeouts and
        # Ecto.MultipleResultsError both surface here under bulk load.
        summary =
          Events.replay_by_types(
            @claimed_slugs,
            fn event -> safe_project_replay(event, "rebuild") end,
            on_batch: fn last_id, processed ->
              Events.put_watermark!(@projector_name, last_id)
              if on_progress, do: on_progress.(min(processed, total), total)
            end
          )

        # Final watermark for any remaining events
        max_id = Events.max_event_id_for_types(@claimed_slugs)
        if max_id > 0, do: Events.put_watermark!(@projector_name, max_id)
        if on_progress, do: on_progress.(total, total)

        log_replay_summary("rebuild", summary)
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

        summary =
          Events.replay_by_types(
            @claimed_slugs,
            fn event -> safe_project_replay(event, "catch-up") end,
            cursor: cursor,
            on_batch: fn last_id, processed ->
              Events.put_watermark!(@projector_name, last_id)
              if on_progress, do: on_progress.(min(processed, total), total)
            end
          )

        max_id = Events.max_event_id_for_types(@claimed_slugs)
        if max_id > 0, do: Events.put_watermark!(@projector_name, max_id)
        if on_progress, do: on_progress.(total, total)

        log_replay_summary("catch-up", summary)
        :ok
      end

      @impl true
      def init(_opts) do
        Topics.subscribe(Topics.domain_events())
        Topics.subscribe(Topics.domain_control())
        after_init(_opts)
        {:ok, %{}}
      end

      def after_init(_opts), do: :ok

      @impl true
      def handle_info(:full_rebuild, state) do
        Log.info(
          :ingester,
          "#{@projector_name}: full rebuild triggered (domain events regenerated)"
        )

        # Watermarks from the prior event store generation are stale — reset before replaying.
        Events.put_watermark!(@projector_name, 0)
        Enum.each(Enum.reverse(@projection_tables), &Scry2.Repo.delete_all/1)

        summary =
          Events.replay_by_types(
            @claimed_slugs,
            fn event -> safe_project_replay(event, "full_rebuild") end,
            on_batch: fn last_id, _ -> Events.put_watermark!(@projector_name, last_id) end
          )

        max_id = Events.max_event_id_for_types(@claimed_slugs)
        if max_id > 0, do: Events.put_watermark!(@projector_name, max_id)

        log_replay_summary("full_rebuild", summary)
        Topics.broadcast(Topics.domain_control(), {:projector_rebuilt, @projector_name})
        {:noreply, state}
      end

      @impl true
      def handle_info(:rebuild_all, state) do
        Log.info(:ingester, "#{@projector_name}: rebuild_all received")

        rebuild!(
          on_progress: fn processed, total ->
            Topics.broadcast(
              Topics.domain_control(),
              {:projector_progress, @projector_name, processed, total}
            )
          end
        )

        Topics.broadcast(Topics.domain_control(), {:projector_rebuilt, @projector_name})
        {:noreply, state}
      end

      @impl true
      def handle_info(:catch_up_all, state) do
        Log.info(:ingester, "#{@projector_name}: catch_up_all received")

        catch_up!(
          on_progress: fn processed, total ->
            Topics.broadcast(
              Topics.domain_control(),
              {:projector_progress, @projector_name, processed, total}
            )
          end
        )

        Topics.broadcast(Topics.domain_control(), {:projector_caught_up, @projector_name})
        {:noreply, state}
      end

      # 4-tuple: event struct included in broadcast — skip DB fetch
      @impl true
      def handle_info({:domain_event, id, type_slug, event}, state)
          when type_slug in @claimed_slugs do
        safe_project_live(event, id, type_slug)
        {:noreply, state}
      end

      # 3-tuple fallback: legacy or catch-up messages — fetch from DB
      @impl true
      def handle_info({:domain_event, id, type_slug}, state)
          when type_slug in @claimed_slugs do
        safe_project_live({:lazy_fetch, id}, id, type_slug)
        {:noreply, state}
      end

      def handle_info({:domain_event, _id, _type_slug, _event}, state), do: {:noreply, state}
      def handle_info({:domain_event, _id, _type_slug}, state), do: {:noreply, state}
      def handle_info(msg, state), do: handle_extra_info(msg, state)

      def handle_extra_info(_msg, state), do: {:noreply, state}

      # ── Shared error-handling helpers ────────────────────────────────────
      # Replay paths catch errors and return `{:error, reason}` so the caller
      # can count failures — silently skipping bad events violates "Data
      # Integrity" (CLAUDE.md). Live paths log an error and advance the
      # watermark only on success.

      defp safe_project_replay(event, phase) do
        try do
          project(event)
          :ok
        rescue
          error ->
            Log.warning(
              :ingester,
              "#{@projector_name} #{phase} skip (rescue): #{inspect(error)}"
            )

            {:error, {:rescue, error}}
        catch
          kind, reason ->
            Log.warning(
              :ingester,
              "#{@projector_name} #{phase} skip (#{kind}): #{inspect(reason) |> String.slice(0, 300)}"
            )

            {:error, {kind, reason}}
        end
      end

      # Logged at info severity for clean rebuilds, error severity when any
      # event was skipped — surfaces silent projection loss so the user can
      # re-run rebuild or investigate before the watermark hides the issue.
      defp log_replay_summary(phase, summary) do
        case summary.failed do
          0 ->
            Log.info(
              :ingester,
              "#{@projector_name}: #{phase} complete (#{summary.processed} events)"
            )

          n ->
            sample = summary.failed_ids |> Enum.take(10) |> inspect()

            Log.error(
              :ingester,
              "#{@projector_name}: #{phase} skipped #{n}/#{summary.processed} events (sample ids: #{sample}). Re-run if errors are transient; investigate logs if persistent."
            )
        end
      end

      defp safe_project_live(event_or_lazy, id, type_slug) do
        try do
          event =
            case event_or_lazy do
              {:lazy_fetch, ^id} -> Events.get!(id)
              loaded -> loaded
            end

          project(event)
          Events.put_watermark!(@projector_name, id)
        rescue
          error ->
            Log.error(
              :ingester,
              "#{__MODULE__} failed on domain_event id=#{id} type=#{type_slug} (rescue): #{inspect(error)}"
            )
        catch
          kind, reason ->
            Log.error(
              :ingester,
              "#{__MODULE__} failed on domain_event id=#{id} type=#{type_slug} (#{kind}): #{inspect(reason) |> String.slice(0, 300)}"
            )
        end
      end

      defoverridable after_init: 1, handle_extra_info: 2
    end
  end
end
