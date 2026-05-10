defmodule Scry2.Workers.PeriodicallyComputeInsights do
  @moduledoc """
  Oban worker that runs every registered insight detector and materialises
  any returned insights to the `insights` table.

  Runs:
  - On a daily cron (configured in `config/config.exs`).
  - Manually via `Scry2.Insights.compute_all/0` from IEx, the Operations
    LiveView, or any future on-demand trigger.

  Uniqueness: a 60-second window prevents stacking duplicates from rapid
  retries. Use `:default` queue — insights compute is light and cheap.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 60]

  alias Scry2.Insights

  require Scry2.Log, as: Log

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, %{computed: count}} = Insights.compute_all()
    Log.info(:importer, "insights compute pass; #{count} insights")
    :ok
  end
end
