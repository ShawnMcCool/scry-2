defmodule Scry2.Insights.Detector do
  @moduledoc """
  Behaviour for an insight detector.

  Each detector is a pure function that reads from one or more domain
  context public APIs and returns either `nil` (no significant pattern
  found) or an unpersisted `%Scry2.Insights.Insight{}` containing the
  measurement, sample size, and confidence.

  Detectors **never generate narrative**. The `:title_template` and
  `:body_template` keys reference template strings rendered at display
  time with the persisted `:stats` and `:measurements`. Only numbers
  vary — wording is fixed per detector type.

  Tier semantics:

    * `1` — pure SQL on existing tables, no significance test required
    * `2` — computed with a significance test (z-test, etc.) before returning

  Adding a detector: implement this behaviour, save the file under
  `lib/scry_2/insights/detectors/`, and register the module in
  `Scry2.Insights.Detectors`. See the existing detectors for reference.
  """

  alias Scry2.Insights.Insight

  @doc """
  Returns either `nil` if no significant pattern was found, or an
  unpersisted `%Insight{}` ready to be inserted by the compute job.

  Callers should not rely on `id`, `inserted_at`, or `updated_at`
  being set on the returned struct.
  """
  @callback detect(opts :: keyword()) :: nil | Insight.t()

  @doc "Tier of this detector. Drives the badge in the rendered tile."
  @callback tier() :: 1 | 2
end
