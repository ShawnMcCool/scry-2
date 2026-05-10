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
      Scry2.Insights.Detectors.EventROI
    ]
  end
end
