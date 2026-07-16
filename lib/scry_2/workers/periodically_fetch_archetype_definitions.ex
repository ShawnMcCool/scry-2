defmodule Scry2.Workers.PeriodicallyFetchArchetypeDefinitions do
  @moduledoc """
  Daily Oban cron worker refreshing the Metagame archetype vocabulary
  from the upstream MTGOFormatData repo via
  `Scry2.Metagame.FetchDefinitions`.

  A fetch failure marks the job failed (visible in Oban) and leaves the
  stored definitions untouched; the next scheduled run retries.
  `:metagame_fetch_req_options` in the application env injects Req
  options for tests.
  """
  use Oban.Worker, queue: :imports, max_attempts: 1, unique: [period: 300]

  alias Scry2.Metagame.FetchDefinitions

  require Scry2.Log, as: Log

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    req_options = Application.get_env(:scry_2, :metagame_fetch_req_options, [])

    case FetchDefinitions.run(req_options: req_options) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Log.warning(:http, "archetype definitions fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
