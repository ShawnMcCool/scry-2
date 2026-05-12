defmodule Scry2.Insights.Detectors do
  @moduledoc """
  Explicit registry of all detector modules.

  Adding a new detector:

    1. Create `Scry2.Insights.Detectors.<Name>` implementing
       `Scry2.Insights.Detector`.
    2. Add the module to `all/0` below.
    3. Test in `test/scry_2/insights/detectors/<name>_test.exs`.

  No auto-discovery — explicit listing makes the directory tree the
  source of truth and prevents accidental shipping of in-progress
  detector modules.
  """

  @doc "Detectors registered for the given surface."
  @spec for_surface(atom()) :: [module()]
  def for_surface(:home), do: all()
  def for_surface(_), do: []

  @doc "All registered detectors, in no particular order."
  @spec all() :: [module()]
  def all do
    [
      Scry2.Insights.Detectors.OnPlayVsOnDraw,
      Scry2.Insights.Detectors.EventROI,
      Scry2.Insights.Detectors.MulliganOutcome,
      Scry2.Insights.Detectors.BO1VsBO3Gap,
      Scry2.Insights.Detectors.P1P1RarityCorrelation,
      Scry2.Insights.Detectors.FormatBaseline,
      Scry2.Insights.Detectors.CraftingVelocity,
      Scry2.Insights.Detectors.DeckHeater,
      Scry2.Insights.Detectors.DeckColorOutlier,
      Scry2.Insights.Detectors.RankMilestone,
      Scry2.Insights.Detectors.DraftConversionRate,
      Scry2.Insights.Detectors.WeekendWarrior,
      Scry2.Insights.Detectors.ComebackArtist
    ]
  end
end
