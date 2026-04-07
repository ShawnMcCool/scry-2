defmodule Scry2.Workers.PeriodicallyBackfillArenaIds do
  @moduledoc """
  Oban worker that backfills `arena_id` from Scryfall bulk data.

  Scheduled weekly via cron (see `config :scry_2, Oban`) and also
  enqueueable on-demand from the dashboard.

  Uniqueness: a 60-second window prevents duplicate stacking.
  """
  use Oban.Worker,
    queue: :imports,
    max_attempts: 3,
    unique: [period: 60]

  alias Scry2.Cards.Scryfall

  require Scry2.Log, as: Log

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    url = Map.get(job.args, "override_url")
    opts = if is_binary(url), do: [url: url], else: []

    case Scryfall.run(opts) do
      {:ok, %{matched: count}} ->
        Log.info(:importer, "scryfall backfill completed — #{count} arena_ids set")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
