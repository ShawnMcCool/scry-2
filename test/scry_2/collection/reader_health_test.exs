defmodule Scry2.Collection.ReaderHealthTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.{ReaderHealth, Snapshot}

  @now ~U[2026-05-21 22:00:00.000000Z]

  defp snap(opts) do
    %Snapshot{
      snapshot_ts: opts[:ts] || @now,
      reader_confidence: opts[:confidence] || "walker",
      mtga_build_hint: opts[:build] || "Build-1.0.0",
      card_count: opts[:card_count] || 250,
      total_copies: opts[:total_copies] || 800
    }
  end

  describe "compute/1" do
    test ":no_snapshot when there is no snapshot" do
      assert %ReaderHealth{status: :no_snapshot, tone: :neutral} =
               ReaderHealth.compute(snapshot: nil, reader_enabled: true, now: @now)
    end

    test ":reader_disabled when the user has switched the reader off" do
      assert %ReaderHealth{status: :reader_disabled, tone: :neutral} =
               ReaderHealth.compute(snapshot: snap([]), reader_enabled: false, now: @now)
    end

    test ":reader_disabled wins over snapshot state" do
      ts = DateTime.add(@now, -10, :second)

      assert %ReaderHealth{status: :reader_disabled} =
               ReaderHealth.compute(
                 snapshot: snap(ts: ts, confidence: "walker"),
                 reader_enabled: false,
                 now: @now
               )
    end

    test ":walker_recent when last walker read is fresh (within 30 minutes)" do
      ts = DateTime.add(@now, -120, :second)

      verdict =
        ReaderHealth.compute(
          snapshot: snap(ts: ts, confidence: "walker"),
          reader_enabled: true,
          now: @now
        )

      assert verdict.status == :walker_recent
      assert verdict.tone == :ok
      assert verdict.label =~ "Reader OK"
      assert verdict.label =~ "2 min ago"
      assert verdict.age_seconds == 120
    end

    test ":walker_stale when last walker read is older than 30 minutes" do
      ts = DateTime.add(@now, -3600, :second)

      verdict =
        ReaderHealth.compute(
          snapshot: snap(ts: ts, confidence: "walker"),
          reader_enabled: true,
          now: @now
        )

      assert verdict.status == :walker_stale
      assert verdict.tone == :warn
      assert verdict.label =~ "stale"
      assert verdict.label =~ "1h ago"
    end

    test ":fallback_in_use surfaces the slower scanner path" do
      ts = DateTime.add(@now, -60, :second)

      verdict =
        ReaderHealth.compute(
          snapshot: snap(ts: ts, confidence: "fallback_scan"),
          reader_enabled: true,
          now: @now
        )

      assert verdict.status == :fallback_in_use
      assert verdict.tone == :warn
      assert verdict.label =~ "Fallback"
    end

    test "label formats seconds, minutes, hours, and days" do
      cases = [
        {5, "5s ago"},
        {59, "59s ago"},
        {60, "1 min ago"},
        {120, "2 min ago"},
        {3599, "59 min ago"},
        {3600, "1h ago"},
        {7200, "2h ago"},
        {86_399, "23h ago"},
        {86_400, "1d ago"},
        {2 * 86_400, "2d ago"}
      ]

      for {seconds, expected_suffix} <- cases do
        ts = DateTime.add(@now, -seconds, :second)

        verdict =
          ReaderHealth.compute(
            snapshot: snap(ts: ts, confidence: "walker"),
            reader_enabled: true,
            now: @now
          )

        assert verdict.label =~ expected_suffix,
               "expected label to contain #{inspect(expected_suffix)} for #{seconds}s, got: #{verdict.label}"
      end
    end

    test "detail string explains what the user is seeing" do
      ts = DateTime.add(@now, -300, :second)

      walker =
        ReaderHealth.compute(
          snapshot: snap(ts: ts, confidence: "walker"),
          reader_enabled: true,
          now: @now
        )

      fallback =
        ReaderHealth.compute(
          snapshot: snap(ts: ts, confidence: "fallback_scan"),
          reader_enabled: true,
          now: @now
        )

      assert is_binary(walker.detail) and walker.detail != ""
      assert is_binary(fallback.detail) and fallback.detail != ""
      assert fallback.detail =~ "fallback" or fallback.detail =~ "slower"
    end
  end
end
