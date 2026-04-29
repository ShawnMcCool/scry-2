defmodule Scry2.Workers.PeriodicallyImportScryfallCards do
  @moduledoc """
  Oban worker that imports Scryfall bulk card data into `cards_scryfall_cards`.

  Scheduled weekly via cron and also enqueueable on-demand from the
  dashboard. Synthesis into `cards_cards` runs separately
  (`Scry2.Workers.PeriodicallySynthesizeCards`).

  Uniqueness: a 60-second window prevents duplicate stacking.
  """
  use Oban.Worker,
    queue: :imports,
    max_attempts: 3,
    unique: [period: 60]

  alias Scry2.Cards
  alias Scry2.Cards.Scryfall

  require Scry2.Log, as: Log

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    url = Map.get(job.args, "override_url")
    opts = if is_binary(url), do: [url: url], else: []

    with {:ok, %{persisted: count}} <- Scryfall.run(opts) do
      Log.info(:importer, "scryfall import completed — #{count} cards persisted")
      :ok = Cards.record_scryfall_refresh!()
      :ok
    end
  end
end
