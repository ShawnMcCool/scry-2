defmodule Scry2.PostDeployTasks.Tasks.SynthesisTokenBoosterFixV1 do
  @moduledoc """
  Re-runs `Scry2.Cards.Synthesize.run/0` after the v0.41.2 fix that
  stops MTGA-only tokens from inheriting the default `is_booster = true`
  fallback. Without this re-run, existing `cards_cards` rows for tokens
  on a v0.40.x or v0.41.x install keep their incorrect
  `is_booster = true` value, which leaves the SetRoster's lag-fallback
  detector counting the set as "tagged" and using the strict booster
  filter (12 cards in SOS, 10 in TMT) instead of the rarity-based
  fallback (~340 cards in SOS, ~270 in TMT). The Collection page's
  set-completion percentages stay wildly inflated (2125%, 1930%) until
  this synthesis re-runs.
  """

  @behaviour Scry2.PostDeployTasks.Task

  alias Scry2.Cards.Synthesize

  @impl true
  def task_id, do: "synthesis.token_booster_fix_v1"

  @impl true
  def description do
    "Re-run card synthesis with the token/booster fix. Required after " <>
      "upgrading to v0.41.2 to clear the incorrect `is_booster = true` " <>
      "value from tokens, which was inflating set-completion percentages " <>
      "for new sets like Secrets of Strixhaven and Teenage Mutant Ninja Turtles."
  end

  @impl true
  def run do
    {:ok, _stats} = Synthesize.run([])
    :ok
  end
end
