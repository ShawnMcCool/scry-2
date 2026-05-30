defmodule Scry2.Events.RawRetentionTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.RawRetention

  describe "coverage_verdict/1" do
    test "zero orphaned domain events is :ok" do
      assert RawRetention.coverage_verdict(0) == :ok
    end

    test "any orphaned domain events is a gap with the count" do
      assert RawRetention.coverage_verdict(1) == {:gap, 1}
      assert RawRetention.coverage_verdict(1_240) == {:gap, 1_240}
    end
  end

  describe "coverage_error_message/1" do
    test "names the count and explains the refusal and the override" do
      message = RawRetention.coverage_error_message(1_240)

      assert message =~ "1240"
      assert message =~ "raw"
      assert message =~ "force: true"
    end
  end

  describe "prune_cutoff/2" do
    test "nil retention means keep forever — no cutoff" do
      assert RawRetention.prune_cutoff(nil, ~U[2026-05-30 12:00:00Z]) == nil
    end

    test "a positive day count yields a cutoff that many days before now" do
      now = ~U[2026-05-30 12:00:00Z]
      assert RawRetention.prune_cutoff(90, now) == ~U[2026-03-01 12:00:00Z]
    end

    test "zero days means the cutoff is now (everything older is prunable)" do
      now = ~U[2026-05-30 12:00:00Z]
      assert RawRetention.prune_cutoff(0, now) == now
    end
  end
end
