defmodule Scry2.Insights.SignificanceTest do
  use ExUnit.Case, async: true

  alias Scry2.Insights.Significance

  describe "two_tailed_p_value/1" do
    test "z = 0 → p = 1.0" do
      assert_in_delta Significance.two_tailed_p_value(0.0), 1.0, 0.001
    end

    test "z = 1.96 → p ≈ 0.05 (the canonical threshold)" do
      assert_in_delta Significance.two_tailed_p_value(1.96), 0.05, 0.005
    end

    test "z = 2.58 → p ≈ 0.01" do
      assert_in_delta Significance.two_tailed_p_value(2.58), 0.01, 0.005
    end

    test "is symmetric around zero" do
      assert Significance.two_tailed_p_value(2.0) ==
               Significance.two_tailed_p_value(-2.0)
    end
  end

  describe "z_test_proportions/4" do
    test "identical proportions → high p-value (no signal)" do
      p = Significance.z_test_proportions(0.50, 100, 0.50, 100)
      assert is_float(p)
      assert p > 0.5
    end

    test "very different proportions on large samples → near-zero p-value" do
      p = Significance.z_test_proportions(0.70, 100, 0.30, 100)
      assert p < 0.001
    end

    test "12-3 vs 53% baseline (87-77, n=164) → significant" do
      p = Significance.z_test_proportions(0.80, 15, 0.530, 164)
      assert is_float(p)
      assert p < 0.05
    end

    test "1-1 vs 50% baseline → not significant (tiny n)" do
      p = Significance.z_test_proportions(0.50, 2, 0.50, 200)
      assert is_float(p)
      assert p > 0.05
    end

    test "degenerate (all wins, all losses) → :undefined" do
      assert Significance.z_test_proportions(1.0, 10, 1.0, 10) == :undefined
      assert Significance.z_test_proportions(0.0, 10, 0.0, 10) == :undefined
    end
  end

  describe "wilson_ci_95/2" do
    test "0/100 returns lower bound at 0.0" do
      {lower, upper} = Significance.wilson_ci_95(0, 100)
      assert lower == 0.0
      assert upper > 0.0
      assert upper < 0.05
    end

    test "100/100 returns upper bound at 1.0" do
      {lower, upper} = Significance.wilson_ci_95(100, 100)
      assert_in_delta upper, 1.0, 1.0e-10
      assert lower > 0.95
      assert lower < 1.0
    end

    test "50/100 brackets 0.5" do
      {lower, upper} = Significance.wilson_ci_95(50, 100)
      assert lower < 0.5
      assert upper > 0.5
      # The Wilson interval at 50/100 is approximately (0.404, 0.596).
      assert_in_delta lower, 0.404, 0.005
      assert_in_delta upper, 0.596, 0.005
    end

    test "tighter bounds with larger n" do
      {lower_small, upper_small} = Significance.wilson_ci_95(50, 100)
      {lower_large, upper_large} = Significance.wilson_ci_95(500, 1000)
      assert upper_small - lower_small > upper_large - lower_large
    end
  end
end
