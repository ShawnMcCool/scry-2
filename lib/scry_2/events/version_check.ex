defmodule Scry2.Events.VersionCheck do
  @moduledoc """
  Startup version check for the event-sourcing pipeline.

  Compares compile-time AST hashes against stored hashes from the
  previous run. If the translator pipeline changed, runs a full
  reingest. If only specific projectors changed, rebuilds only those.

  Runs synchronously during application startup — before projectors
  start — via the `:ignore` GenServer pattern. Returns `:ignore` from
  `init/1` so the supervisor moves on to the next child.
  """

  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Events
  alias Scry2.Events.PipelineHash
  alias Scry2.Events.ProjectorRegistry

  @translator_key "__translator__"

  @typedoc "Action determined by the version check."
  @type action ::
          :store_initial
          | :reingest
          | {:rebuild_projectors, [module()]}
          | :up_to_date

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [])

  @impl true
  def init([]) do
    action = determine_action()
    execute!(action)
    :ignore
  end

  @doc """
  Determines what rebuild action is needed by comparing stored hashes
  against compiled hashes. Pure read — no side effects beyond DB reads.

  Returns one of:
  - `:store_initial` — first run, no stored hashes
  - `:reingest` — translator pipeline changed
  - `{:rebuild_projectors, [mod]}` — only specific projectors changed
  - `:up_to_date` — everything matches
  """
  @spec determine_action() :: action()
  def determine_action do
    stored = Events.get_content_hash(@translator_key)
    current = PipelineHash.translator_hash()

    cond do
      is_nil(stored) ->
        :store_initial

      stored != current ->
        :reingest

      true ->
        case find_stale_projectors() do
          [] -> :up_to_date
          stale -> {:rebuild_projectors, stale}
        end
    end
  end

  @doc "Executes the action returned by `determine_action/0`."
  @spec execute!(action()) :: :ok
  def execute!(:store_initial) do
    Log.info(:ingester, "version_check: first run, storing pipeline hashes")
    store_all_hashes!()
  end

  def execute!(:reingest) do
    Log.info(:ingester, "version_check: translator hash changed, running full reingest")
    Events.reingest!()
    store_all_hashes!()
  end

  def execute!({:rebuild_projectors, stale}) do
    names = Enum.map_join(stale, ", ", & &1.projector_name())
    Log.info(:ingester, "version_check: projector hash changed for: #{names}, rebuilding")

    Task.Supervisor.async_stream(
      Scry2.TaskSupervisor,
      stale,
      & &1.rebuild!(),
      timeout: :infinity
    )
    |> Stream.run()

    Enum.each(stale, fn mod ->
      Events.put_content_hash!(mod.projector_name(), mod.content_hash())
    end)
  end

  def execute!(:up_to_date), do: :ok

  defp find_stale_projectors do
    ProjectorRegistry.all()
    |> Enum.filter(fn mod ->
      stored = Events.get_content_hash(mod.projector_name())
      current = mod.content_hash()

      cond do
        is_nil(stored) ->
          Events.put_content_hash!(mod.projector_name(), current)
          false

        stored != current ->
          true

        true ->
          false
      end
    end)
  end

  defp store_all_hashes! do
    Events.put_content_hash!(@translator_key, PipelineHash.translator_hash())

    Enum.each(ProjectorRegistry.all(), fn mod ->
      Events.put_content_hash!(mod.projector_name(), mod.content_hash())
    end)
  end
end
