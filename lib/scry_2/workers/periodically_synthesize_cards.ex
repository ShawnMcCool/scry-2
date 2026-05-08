defmodule Scry2.Workers.PeriodicallySynthesizeCards do
  @moduledoc """
  Oban worker that synthesises `cards_cards` from `cards_mtga_cards` +
  `cards_scryfall_cards`.

  Runs:
  - On boot via `Scry2.Cards.Bootstrap` when `cards_cards` is empty or stale.
  - On a daily cron after the upstream MTGA + Scryfall imports finish.
  - Manually from the Cards LiveView "refresh" button.

  Uniqueness: a 60-second window prevents stacking duplicates from rapid
  retries or boot/cron racing.
  """
  use Oban.Worker,
    queue: :imports,
    max_attempts: 3,
    unique: [period: 60]

  alias Scry2.Cards
  alias Scry2.Cards.Synthesize

  require Scry2.Log, as: Log

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, %{synthesized: count}} = Synthesize.run()
    :ok = Cards.record_synthesis_refresh!()
    Log.info(:importer, "card synthesis succeeded; #{count} cards")
    :ok
  end
end
