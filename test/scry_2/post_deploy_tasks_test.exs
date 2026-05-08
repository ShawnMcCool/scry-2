defmodule Scry2.PostDeployTasksTest do
  use Scry2.DataCase, async: true

  alias Scry2.PostDeployTasks

  describe "classify/2 (pure)" do
    test "no applied marker, no in-flight job → :pending" do
      assert PostDeployTasks.classify(nil, nil) == :pending
    end

    test "applied marker present, no in-flight job → :applied" do
      assert PostDeployTasks.classify(~U[2026-05-08 12:00:00Z], nil) == :applied
    end

    test "in-flight Oban states → :running" do
      for state <- [:executing, :scheduled, :available, :retryable] do
        assert PostDeployTasks.classify(nil, state) == :running
      end
    end

    test "in-flight wins over applied marker (re-run scenario)" do
      assert PostDeployTasks.classify(~U[2026-05-08 12:00:00Z], :executing) == :running
    end

    test "discarded → :failed" do
      assert PostDeployTasks.classify(nil, :discarded) == :failed
    end

    test "completed terminal state with no applied marker → :pending" do
      # Should never happen in practice (the worker writes the marker on
      # success), but the classifier doesn't crash if it sees an old
      # completed job without a corresponding marker.
      assert PostDeployTasks.classify(nil, :completed) == :pending
    end
  end

  describe "applied?/1 + mark_applied!/1" do
    test "fresh task is not applied" do
      refute PostDeployTasks.applied?("test.fresh_v1")
    end

    test "mark_applied! makes the task applied" do
      :ok = PostDeployTasks.mark_applied!("test.marked_v1")
      assert PostDeployTasks.applied?("test.marked_v1")
    end

    test "mark_applied! is idempotent — repeated calls overwrite the timestamp" do
      :ok = PostDeployTasks.mark_applied!("test.repeated_v1")
      assert PostDeployTasks.applied?("test.repeated_v1")
      :ok = PostDeployTasks.mark_applied!("test.repeated_v1")
      assert PostDeployTasks.applied?("test.repeated_v1")
    end
  end

  describe "lookup/1" do
    test "returns the SynthesisAlgoV2 module for its declared id" do
      assert PostDeployTasks.lookup("synthesis.algo_v2") ==
               Scry2.PostDeployTasks.Tasks.SynthesisAlgoV2
    end

    test "returns nil for an unregistered id" do
      assert PostDeployTasks.lookup("nope.never_v1") == nil
    end
  end

  describe "list/0" do
    test "returns one entry per registered task with status :pending on a clean install" do
      entries = PostDeployTasks.list()
      assert length(entries) == length(PostDeployTasks.registered_tasks())

      synth = Enum.find(entries, &(&1.id == "synthesis.algo_v2"))
      assert synth != nil
      assert synth.module == Scry2.PostDeployTasks.Tasks.SynthesisAlgoV2
      assert is_binary(synth.description)
      assert synth.status == :pending
      assert synth.applied_at == nil
    end

    test "applied marker flips status to :applied" do
      :ok = PostDeployTasks.mark_applied!("synthesis.algo_v2")
      synth = PostDeployTasks.list() |> Enum.find(&(&1.id == "synthesis.algo_v2"))
      assert synth.status == :applied
      assert %DateTime{} = synth.applied_at
    end
  end
end
