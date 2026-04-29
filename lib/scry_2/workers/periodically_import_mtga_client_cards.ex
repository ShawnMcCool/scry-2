defmodule Scry2.Workers.PeriodicallyImportMtgaClientCards do
  @moduledoc """
  Oban worker that imports card identity data from the MTGA client's
  local `Raw_CardDatabase_*.mtga` SQLite file.

  Triggered on application boot via `Scry2.Cards.Bootstrap` when the
  `cards_mtga_cards` table is empty or the last import is older than
  the staleness threshold (7 days). Also runs daily on a cron so newly
  released sets get picked up shortly after MTGA pushes a content patch.

  Uniqueness: a 60-second window prevents stacking duplicates from rapid
  retries or boot/cron racing.
  """
  use Oban.Worker,
    queue: :imports,
    max_attempts: 3,
    unique: [period: 60]

  alias Scry2.Cards
  alias Scry2.Cards.MtgaClientData

  require Scry2.Log, as: Log

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case MtgaClientData.run() do
      {:ok, %{imported: count}} ->
        :ok = Cards.record_mtga_client_refresh!()
        Log.info(:importer, "mtga client import succeeded; #{count} cards upserted")
        :ok

      {:error, :database_not_found} ->
        # Treat missing client DB as a soft skip — users without MTGA
        # installed (or with the path unset) shouldn't see retry storms.
        Log.info(:importer, "mtga client import skipped: client database not found")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
