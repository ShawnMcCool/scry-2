defmodule Scry2.Workers.CardsRefreshWorker do
  @moduledoc """
  Oban worker that refreshes card reference data from 17lands.

  Scheduled via cron (see `config :scry_2, Oban`) and also enqueueable
  on-demand from the dashboard "Refresh cards now" button.

  Uniqueness: a 60-second window prevents double-clicks from stacking
  up duplicate jobs. Legitimate consecutive refreshes will queue
  normally on the next tick.
  """
  use Oban.Worker,
    queue: :imports,
    max_attempts: 3,
    unique: [period: 60]

  alias Scry2.Cards.Lands17Importer

  require Scry2.Log, as: Log

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    # Args are JSON — string keys only. `override_url` lets the settings
    # LiveView target a mirror or test fixture without redeploying.
    url = Map.get(job.args, "override_url")

    opts = if is_binary(url), do: [url: url], else: []

    case Lands17Importer.run(opts) do
      {:ok, %{imported: count}} ->
        Log.info(:importer, "cards refresh imported #{count} rows")
        :ok

      {:error, reason} ->
        # Let Oban retry with its backoff. Returning `{:error, _}` flags
        # the job as a failure in the database.
        {:error, reason}
    end
  end
end
