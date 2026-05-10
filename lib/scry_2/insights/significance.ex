defmodule Scry2.Insights.Significance do
  @moduledoc """
  Statistical helpers shared by Tier-2 detectors.

  Provides two-proportion z-tests and Wilson score confidence intervals.
  All functions are pure.

  Conventions:

    * Proportions are floats in `[0.0, 1.0]`
    * p-values are floats in `[0.0, 1.0]`
    * Sample sizes are positive integers

  Detectors should also enforce minimum sample sizes before calling these
  helpers — significance is meaningless on tiny samples.
  """

  @doc """
  Two-proportion z-test. Returns the two-tailed p-value, or `:undefined`
  when sample sizes are too small or proportions are degenerate (pooled
  proportion 0.0 or 1.0, zero standard error).

  Used to test whether two observed proportions (e.g. 12-3 vs 87-77)
  differ more than chance would predict.
  """
  @spec z_test_proportions(float(), pos_integer(), float(), pos_integer()) ::
          float() | :undefined
  def z_test_proportions(p1, n1, p2, n2)
      when is_float(p1) and is_integer(n1) and n1 > 0 and
             is_float(p2) and is_integer(n2) and n2 > 0 do
    pooled = (p1 * n1 + p2 * n2) / (n1 + n2)

    if pooled <= 0.0 or pooled >= 1.0 do
      :undefined
    else
      se = :math.sqrt(pooled * (1 - pooled) * (1 / n1 + 1 / n2))

      if se <= 0.0 do
        :undefined
      else
        z = (p1 - p2) / se
        two_tailed_p_value(z)
      end
    end
  end

  @doc """
  Wilson score 95% confidence interval for a single proportion. Returns
  `{lower, upper}` bounds in `[0, 1]`. More robust than the normal
  approximation at boundary values.
  """
  @spec wilson_ci_95(non_neg_integer(), pos_integer()) :: {float(), float()}
  def wilson_ci_95(successes, n)
      when is_integer(successes) and is_integer(n) and n > 0 and successes >= 0 and successes <= n do
    z = 1.96
    p = successes / n
    z2 = z * z
    denom = 1 + z2 / n
    centre = (p + z2 / (2 * n)) / denom
    margin = z * :math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / denom
    {max(centre - margin, 0.0), min(centre + margin, 1.0)}
  end

  @doc """
  Two-tailed p-value from a z-score. Uses the Abramowitz & Stegun 26.2.17
  approximation of the standard normal CDF (error < 1.5e-7).
  """
  @spec two_tailed_p_value(float()) :: float()
  def two_tailed_p_value(z) when is_float(z) do
    2 * (1 - normal_cdf(abs(z)))
  end

  defp normal_cdf(x) do
    t = 1 / (1 + 0.2316419 * x)

    poly =
      0.319381530 * t -
        0.356563782 * t * t +
        1.781477937 * :math.pow(t, 3) -
        1.821255978 * :math.pow(t, 4) +
        1.330274429 * :math.pow(t, 5)

    1 - normal_pdf(x) * poly
  end

  defp normal_pdf(x), do: :math.exp(-x * x / 2) / :math.sqrt(2 * :math.pi())
end
