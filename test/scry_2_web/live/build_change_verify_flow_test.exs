defmodule Scry2Web.BuildChangeVerifyFlowTest do
  use ExUnit.Case, async: true

  alias Scry2Web.BuildChangeVerifyFlow

  test "idle carries no detail and no attempt hint" do
    assert BuildChangeVerifyFlow.idle() == %{
             verify_state: :idle,
             verify_detail: nil,
             verify_attempt_hint: nil
           }
  end

  test "start records the build under verification from the change status" do
    verify = BuildChangeVerifyFlow.start({:changed, "OLD", "NEW"})

    assert verify.verify_state == :running
    assert verify.verify_attempt_hint == "NEW"
    assert verify.verify_detail == nil
  end

  test "start without a change status runs with no hint" do
    assert %{verify_state: :running, verify_attempt_hint: nil} =
             BuildChangeVerifyFlow.start(:current)
  end

  describe "classify_snapshot/2" do
    setup do
      %{running: BuildChangeVerifyFlow.start({:changed, "OLD", "NEW"})}
    end

    test "a walker snapshot of the attempted build verifies", %{running: running} do
      snapshot = %{reader_confidence: "walker", mtga_build_hint: "NEW"}

      assert %{verify_state: :ok, verify_detail: nil} =
               BuildChangeVerifyFlow.classify_snapshot(running, snapshot)
    end

    test "a walker snapshot of a different build stays running", %{running: running} do
      snapshot = %{reader_confidence: "walker", mtga_build_hint: "STALE"}

      assert %{verify_state: :running} =
               BuildChangeVerifyFlow.classify_snapshot(running, snapshot)
    end

    test "a fallback-scan snapshot classifies as fallback", %{running: running} do
      snapshot = %{reader_confidence: "fallback_scan", mtga_build_hint: "NEW"}

      assert %{verify_state: :fallback} =
               BuildChangeVerifyFlow.classify_snapshot(running, snapshot)
    end

    test "no snapshot yet stays running", %{running: running} do
      assert %{verify_state: :running} = BuildChangeVerifyFlow.classify_snapshot(running, nil)
    end

    test "does nothing unless a verification is running" do
      idle = BuildChangeVerifyFlow.idle()
      snapshot = %{reader_confidence: "walker", mtga_build_hint: "NEW"}

      assert BuildChangeVerifyFlow.classify_snapshot(idle, snapshot) == idle
    end
  end

  describe "failure and timeout" do
    test "failed maps mtga_not_running to its own banner state" do
      assert %{verify_state: :mtga_not_running} = BuildChangeVerifyFlow.failed(:mtga_not_running)
    end

    test "failed carries the player-language translation for other reasons" do
      failed = BuildChangeVerifyFlow.failed(:process_not_found)

      assert failed.verify_state == :failed
      assert is_binary(failed.verify_detail)
    end

    test "classify_failure only acts on a running verification" do
      running = BuildChangeVerifyFlow.start({:changed, "OLD", "NEW"})
      idle = BuildChangeVerifyFlow.idle()

      assert %{verify_state: :failed} =
               BuildChangeVerifyFlow.classify_failure(running, :walk_failed)

      assert BuildChangeVerifyFlow.classify_failure(idle, :walk_failed) == idle
    end

    test "timeout fails a running verification and leaves any other state alone" do
      running = BuildChangeVerifyFlow.start({:changed, "OLD", "NEW"})

      assert %{verify_state: :failed, verify_detail: detail} =
               BuildChangeVerifyFlow.timeout(running)

      assert detail =~ "longer than expected"

      ok = BuildChangeVerifyFlow.verified()
      assert BuildChangeVerifyFlow.timeout(ok) == ok
    end
  end

  test "verified is the terminal ok state" do
    assert BuildChangeVerifyFlow.verified() == %{
             verify_state: :ok,
             verify_detail: nil,
             verify_attempt_hint: nil
           }
  end
end
