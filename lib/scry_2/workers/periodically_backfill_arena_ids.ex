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

  alias Scry2.Cards
  alias Scry2.Cards.Scryfall

  require Scry2.Log, as: Log

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    url = Map.get(job.args, "override_url")
    opts = if is_binary(url), do: [url: url], else: []

    with {:ok, %{matched: scryfall_count}} <- Scryfall.run(opts) do
      Log.info(:importer, "scryfall backfill completed — #{scryfall_count} arena_ids set")

      client_count = Cards.backfill_arena_ids_from_client_data!()

      if client_count > 0 do
        Log.info(:importer, "client data backfill — #{client_count} arena_ids set")
      end

      :ok
    end
  end
end
