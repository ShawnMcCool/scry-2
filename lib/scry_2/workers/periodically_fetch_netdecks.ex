defmodule Scry2.Workers.PeriodicallyFetchNetdecks do
  @moduledoc """
  Oban cron worker that refreshes the NetDecking catalog from the enabled
  sources. Each source runs in isolation: a source that raises or fails is
  logged and skipped so it can never abort the others or fail the cron. The
  ingestion funnel only upserts, so a failed fetch means "no new decks," never
  data loss — this graceful degradation is a deliberate exception to
  let-it-crash (see the NetDecking sourcing ADR).

  Scheduled daily (mtgo.com publishes Standard Challenges daily); also
  enqueueable on demand from the dashboard. Runs on the always-on dev instance
  via the base crontab, like the other `Periodically*` workers.

  Enabled sources come from `config :scry_2, :netdecking_sources`, overridable
  per-job via the `"sources"` arg (a list of module-name strings).
  """
  use Oban.Worker, queue: :imports, max_attempts: 1, unique: [period: 300]

  alias Scry2.NetDecking.IngestSource
  alias Scry2.NetDecking.Sources.{LocalJsonSource, MtgoSource}

  require Scry2.Log, as: Log

  @default_sources [LocalJsonSource, MtgoSource]

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    job.args
    |> Map.get("sources")
    |> resolve_sources()
    |> Enum.each(&run_isolated/1)

    :ok
  end

  defp resolve_sources(nil),
    do: Application.get_env(:scry_2, :netdecking_sources, @default_sources)

  defp resolve_sources(list) when is_list(list), do: Enum.map(list, &to_module/1)

  defp to_module(module) when is_atom(module), do: module
  defp to_module(name) when is_binary(name), do: Module.concat([name])

  defp run_isolated(source) do
    IngestSource.run(source)
  rescue
    error ->
      Log.error(
        :importer,
        "netdeck source #{inspect(source)} crashed: #{Exception.message(error)}"
      )
  end
end
