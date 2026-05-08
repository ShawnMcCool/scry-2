defmodule Scry2.Cards.Bootstrap do
  @moduledoc """
  Boot-time card reference data bootstrap.

  Runs once at application startup (after Oban is ready) and enqueues
  jobs to refresh any source whose data is missing or stale. The full
  pipeline is:

  1. **MTGA client import** — reads `Raw_CardDatabase_*.mtga` into
     `cards_mtga_cards`.
  2. **Scryfall import** — pulls Scryfall bulk data into
     `cards_scryfall_cards`.
  3. **Synthesis** — builds `cards_cards` from the two sources.

  This module decides which of these to enqueue based on table counts and
  last-refresh timestamps. Synthesis is enqueued whenever the upstream
  sources are refreshed, since stale synthesis data is otherwise hidden
  until the next daily cron tick.

  The module is gated on `Scry2.Config.get(:start_importer)` — when
  importers are disabled (test env, or users who opt out), `run/0` is
  a no-op.

  ## Staleness

  Card data is considered stale after `@stale_threshold_days` days. The
  daily synthesis cron is scheduled for 05:30 UTC; 7 days is a comfortable
  margin that still catches "I haven't run the app in over a week" without
  re-running constantly.

  ## Testability

  The decision logic (`decide/3`) is a pure function that takes its
  inputs as arguments and returns the list of jobs that should be
  enqueued. `run/0` is the thin side-effectful wrapper that collects
  real data and dispatches to Oban.
  """

  require Scry2.Log, as: Log

  alias Scry2.Cards
  alias Scry2.Config
  alias Scry2.Workers.PeriodicallyImportMtgaClientCards
  alias Scry2.Workers.PeriodicallyImportScryfallCards
  alias Scry2.Workers.PeriodicallySynthesizeCards

  @stale_threshold_days 7

  @type job_tag :: :mtga_client | :scryfall | :synthesize

  @doc """
  Enqueues card refresh jobs if needed. Returns the list of job tags
  actually enqueued.
  """
  @spec run() :: [job_tag()]
  def run do
    if Config.get(:start_importer) == false do
      Log.info(:importer, "card bootstrap skipped (start_importer=false)")
      []
    else
      counts = %{
        mtga_client: Cards.mtga_client_count(),
        scryfall: Cards.scryfall_count(),
        synthesized: Cards.count()
      }

      to_enqueue = decide(counts, Cards.import_timestamps(), DateTime.utc_now())

      Enum.each(to_enqueue, &dispatch/1)
      to_enqueue
    end
  end

  @doc """
  Pure decision function: given the current database state, returns
  the list of job tags that should be enqueued.

  ## Arguments

    * `counts` — `%{mtga_client: int, scryfall: int, synthesized: int}`
    * `timestamps` — `Scry2.Cards.import_timestamps/0` result
    * `now` — current time (injected for determinism)
  """
  @spec decide(
          %{
            mtga_client: non_neg_integer(),
            scryfall: non_neg_integer(),
            synthesized: non_neg_integer()
          },
          %{
            mtga_client_updated_at: DateTime.t() | nil,
            scryfall_updated_at: DateTime.t() | nil,
            synthesized_updated_at: DateTime.t() | nil
          },
          DateTime.t()
        ) :: [job_tag()]
  def decide(counts, timestamps, now) do
    %{
      mtga_client: mtga_client_count,
      scryfall: scryfall_count,
      synthesized: synthesized_count
    } = counts

    %{
      mtga_client_updated_at: mtga_client_at,
      scryfall_updated_at: scryfall_at,
      synthesized_updated_at: synthesized_at
    } = timestamps

    mtga_client = if needs?(mtga_client_count, mtga_client_at, now), do: :mtga_client
    scryfall = if needs?(scryfall_count, scryfall_at, now), do: :scryfall
    synthesize = if needs?(synthesized_count, synthesized_at, now), do: :synthesize

    [mtga_client, scryfall, synthesize] |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns true when a data source needs refreshing: either missing
  entirely (`count == 0`) or older than the staleness threshold.
  Pure — useful for direct testing.
  """
  @spec needs?(non_neg_integer(), DateTime.t() | nil, DateTime.t()) :: boolean()
  def needs?(0, _updated_at, _now), do: true
  def needs?(_count, updated_at, now), do: stale?(updated_at, now)

  @doc """
  Returns true when `updated_at` is older than the 7-day staleness
  threshold. `nil` is treated as stale (missing timestamps are
  equivalent to missing data).
  """
  @spec stale?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def stale?(nil, _now), do: true

  def stale?(%DateTime{} = updated_at, %DateTime{} = now) do
    DateTime.diff(now, updated_at, :day) > @stale_threshold_days
  end

  defp dispatch(:mtga_client) do
    case Oban.insert(PeriodicallyImportMtgaClientCards.new(%{})) do
      {:ok, _job} ->
        Log.info(:importer, "card bootstrap enqueued MTGA client import")

      {:error, reason} ->
        Log.warning(:importer, "card bootstrap MTGA client enqueue failed: #{inspect(reason)}")
    end
  end

  defp dispatch(:scryfall) do
    case Oban.insert(PeriodicallyImportScryfallCards.new(%{})) do
      {:ok, _job} ->
        Log.info(:importer, "card bootstrap enqueued Scryfall import")

      {:error, reason} ->
        Log.warning(:importer, "card bootstrap Scryfall enqueue failed: #{inspect(reason)}")
    end
  end

  defp dispatch(:synthesize) do
    case Oban.insert(PeriodicallySynthesizeCards.new(%{})) do
      {:ok, _job} ->
        Log.info(:importer, "card bootstrap enqueued synthesis")

      {:error, reason} ->
        Log.warning(:importer, "card bootstrap synthesis enqueue failed: #{inspect(reason)}")
    end
  end
end
