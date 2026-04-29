defmodule Scry2.Cards.Bootstrap do
  @moduledoc """
  Boot-time card reference data bootstrap.

  Runs once at application startup (after Oban is ready) and enqueues
  the 17lands import and Scryfall backfill jobs if the card data is
  missing or stale. This replaces the behaviour of waiting up to 24
  hours for the next daily cron window on a fresh install.

  The module is gated on `Scry2.Config.get(:start_importer)` — when
  importers are disabled (test env, or users who opt out), `run/0` is
  a no-op.

  ## Staleness

  Card data is considered stale after `@stale_threshold_days` days. The
  daily cron is scheduled for 04:00 UTC, so normally the data refreshes
  every ~24 hours; 7 days is a comfortable margin that still catches
  "I haven't run the app in over a week" without re-running constantly.

  ## Testability

  The decision logic (`decide/4`) is a pure function that takes its
  inputs as arguments and returns the list of jobs that should be
  enqueued. `run/0` is the thin side-effectful wrapper that collects
  real data and dispatches to Oban.
  """

  require Scry2.Log, as: Log

  alias Scry2.Cards
  alias Scry2.Config
  alias Scry2.Workers.PeriodicallyBackfillArenaIds
  alias Scry2.Workers.PeriodicallyImportMtgaClientCards
  alias Scry2.Workers.PeriodicallyUpdateCards

  @stale_threshold_days 7

  @type job_tag :: :lands17 | :scryfall | :mtga_client

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
        lands17: Cards.count(),
        scryfall: Cards.scryfall_count(),
        mtga_client: Cards.mtga_client_count()
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

    * `counts` — `%{lands17: int, scryfall: int, mtga_client: int}`
    * `timestamps` — `Scry2.Cards.import_timestamps/0` result
    * `now` — current time (injected for determinism)
  """
  @spec decide(
          %{
            lands17: non_neg_integer(),
            scryfall: non_neg_integer(),
            mtga_client: non_neg_integer()
          },
          %{
            lands17_updated_at: DateTime.t() | nil,
            scryfall_updated_at: DateTime.t() | nil,
            mtga_client_updated_at: DateTime.t() | nil
          },
          DateTime.t()
        ) :: [job_tag()]
  def decide(counts, timestamps, now) do
    %{lands17: lands17_count, scryfall: scryfall_count, mtga_client: mtga_client_count} = counts

    %{
      lands17_updated_at: lands17_at,
      scryfall_updated_at: scryfall_at,
      mtga_client_updated_at: mtga_client_at
    } = timestamps

    lands17 = if needs?(lands17_count, lands17_at, now), do: :lands17
    scryfall = if needs?(scryfall_count, scryfall_at, now), do: :scryfall
    mtga_client = if needs?(mtga_client_count, mtga_client_at, now), do: :mtga_client

    [lands17, scryfall, mtga_client] |> Enum.reject(&is_nil/1)
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

  defp dispatch(:lands17) do
    case Oban.insert(PeriodicallyUpdateCards.new(%{})) do
      {:ok, _job} ->
        Log.info(:importer, "card bootstrap enqueued 17lands import")

      {:error, reason} ->
        Log.warning(:importer, "card bootstrap 17lands enqueue failed: #{inspect(reason)}")
    end
  end

  defp dispatch(:scryfall) do
    case Oban.insert(PeriodicallyBackfillArenaIds.new(%{})) do
      {:ok, _job} ->
        Log.info(:importer, "card bootstrap enqueued Scryfall backfill")

      {:error, reason} ->
        Log.warning(:importer, "card bootstrap Scryfall enqueue failed: #{inspect(reason)}")
    end
  end

  defp dispatch(:mtga_client) do
    case Oban.insert(PeriodicallyImportMtgaClientCards.new(%{})) do
      {:ok, _job} ->
        Log.info(:importer, "card bootstrap enqueued MTGA client import")

      {:error, reason} ->
        Log.warning(:importer, "card bootstrap MTGA client enqueue failed: #{inspect(reason)}")
    end
  end
end
