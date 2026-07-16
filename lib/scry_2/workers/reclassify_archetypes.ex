defmodule Scry2.Workers.ReclassifyArchetypes do
  @moduledoc """
  Re-stamps every stored archetype classification — netdecks, player
  decks + versions, and opponent archetypes on matches — against the
  current Metagame definitions. Enqueued by
  `Scry2.Metagame.FetchDefinitions` when an upstream refresh changes the
  vocabulary; safe to enqueue manually after engine changes.

  Each context re-stamps in isolation: a failure in one logs and moves
  on rather than aborting the others (classifications are disposable
  projections and the next run heals them).
  """
  use Oban.Worker, queue: :imports, max_attempts: 1, unique: [period: 300]

  require Scry2.Log, as: Log

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    run_isolated("netdecks", &Scry2.NetDecking.reclassify_archetypes!/0)
    run_isolated("player decks", &Scry2.Decks.reclassify_archetypes!/0)
    run_isolated("opponent archetypes", &Scry2.Matches.reclassify_opponent_archetypes!/0)
    :ok
  end

  defp run_isolated(scope, reclassify) do
    changed = reclassify.()
    Log.info(:importer, "reclassify archetypes: #{scope} — #{changed} rows changed")
  rescue
    error ->
      Log.error(
        :importer,
        "reclassify archetypes: #{scope} failed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )
  end
end
