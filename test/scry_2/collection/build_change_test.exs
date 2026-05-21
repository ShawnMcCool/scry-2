defmodule Scry2.Collection.BuildChangeTest do
  use ExUnit.Case, async: true
  alias Scry2.Collection.{BuildChange, Snapshot}

  describe "detect/2" do
    test "no current build_hint → :no_data" do
      assert BuildChange.detect(nil, nil) == :no_data
      assert BuildChange.detect("BUILD-123", nil) == :no_data
    end

    test "no acknowledged but current present → :first_seen" do
      assert BuildChange.detect(nil, "BUILD-123") == :first_seen
    end

    test "acknowledged equals current → :current" do
      assert BuildChange.detect("BUILD-123", "BUILD-123") == :current
    end

    test "acknowledged differs from current → {:changed, prev, current}" do
      assert BuildChange.detect("BUILD-123", "BUILD-456") ==
               {:changed, "BUILD-123", "BUILD-456"}
    end
  end

  describe "verification_state/2" do
    test "walker confidence + build_hint matches current → :already_verified" do
      snapshot = %Snapshot{
        reader_confidence: "walker",
        mtga_build_hint: "BUILD-456",
        snapshot_ts: DateTime.utc_now()
      }

      assert BuildChange.verification_state(snapshot, {:changed, "BUILD-123", "BUILD-456"}) ==
               :already_verified
    end

    test "walker confidence + build_hint mismatch → :unverified" do
      snapshot = %Snapshot{
        reader_confidence: "walker",
        mtga_build_hint: "BUILD-OLD",
        snapshot_ts: DateTime.utc_now()
      }

      assert BuildChange.verification_state(snapshot, {:changed, "BUILD-123", "BUILD-456"}) ==
               :unverified
    end

    test "fallback_scan confidence → :unverified even when build matches" do
      snapshot = %Snapshot{
        reader_confidence: "fallback_scan",
        mtga_build_hint: "BUILD-456",
        snapshot_ts: DateTime.utc_now()
      }

      assert BuildChange.verification_state(snapshot, {:changed, "BUILD-123", "BUILD-456"}) ==
               :unverified
    end

    test "nil snapshot → :unverified" do
      assert BuildChange.verification_state(nil, {:changed, "BUILD-123", "BUILD-456"}) ==
               :unverified
    end

    test "non-:changed status → :unverified (no banner to resolve)" do
      snapshot = %Snapshot{
        reader_confidence: "walker",
        mtga_build_hint: "BUILD-456",
        snapshot_ts: DateTime.utc_now()
      }

      assert BuildChange.verification_state(snapshot, :current) == :unverified
      assert BuildChange.verification_state(snapshot, :no_data) == :unverified
      assert BuildChange.verification_state(snapshot, :first_seen) == :unverified
    end
  end
end
