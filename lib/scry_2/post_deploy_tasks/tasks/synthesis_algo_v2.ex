defmodule Scry2.PostDeployTasks.Tasks.SynthesisAlgoV2 do
  @moduledoc """
  Re-runs `Scry2.Cards.Synthesize.run/0` once after the upgrade that
  introduced the `(set_code, collector_number)`-keyed join (ADR-038).

  Existing `cards_cards` rows on a v0.39.x install were synthesised
  with the old `arena_id`-keyed join, so they're missing Scryfall
  enrichment for sets where Scryfall hasn't backfilled `arena_id` yet
  (SOS / TMT / TLA today, future Standard releases at every set drop).
  Until this task runs once with the new code, the user sees bare
  set codes on the Collection page.
  """

  @behaviour Scry2.PostDeployTasks.Task

  alias Scry2.Cards.Synthesize

  @impl true
  def task_id, do: "synthesis.algo_v2"

  @impl true
  def description do
    "Re-run card synthesis with the (set, number)-keyed join (ADR-038). " <>
      "Required after upgrading to v0.40.x to populate Scryfall metadata for " <>
      "sets where Scryfall has not yet tagged Arena IDs (e.g. Secrets of " <>
      "Strixhaven, Teenage Mutant Ninja Turtles, Avatar: The Last Airbender)."
  end

  @impl true
  def run do
    {:ok, _stats} = Synthesize.run([])
    :ok
  end
end
