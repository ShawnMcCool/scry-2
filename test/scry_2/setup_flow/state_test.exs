defmodule Scry2.SetupFlow.StateTest do
  use ExUnit.Case, async: true

  alias Scry2.SetupFlow.State

  describe "steps/0 and total_steps/0" do
    test "has exactly six canonical steps in order" do
      assert State.steps() == [
               :welcome,
               :locate_log,
               :card_status,
               :verify_events,
               :memory_reading,
               :done
             ]

      assert State.total_steps() == 6
    end
  end

  describe "step_number/1" do
    test "returns 1-based index" do
      assert State.step_number(:welcome) == 1
      assert State.step_number(:locate_log) == 2
      assert State.step_number(:card_status) == 3
      assert State.step_number(:verify_events) == 4
      assert State.step_number(:memory_reading) == 5
      assert State.step_number(:done) == 6
    end
  end

  describe "advance/1" do
    test "moves welcome → locate_log and marks welcome complete" do
      state = %State{step: :welcome}
      next = State.advance(state)

      assert next.step == :locate_log
      assert MapSet.member?(next.completed_steps, :welcome)
    end

    test "walks through every step to :done" do
      %State{step: step} =
        %State{step: :welcome}
        |> State.advance()
        |> State.advance()
        |> State.advance()
        |> State.advance()
        |> State.advance()

      assert step == :done
    end

    test "completed_steps accumulates as the user walks forward" do
      state = %State{step: :welcome}

      final =
        state
        |> State.advance()
        |> State.advance()
        |> State.advance()

      assert MapSet.equal?(
               final.completed_steps,
               MapSet.new([:welcome, :locate_log, :card_status])
             )

      assert final.step == :verify_events
    end

    test "at :done further advances are no-ops" do
      state = %State{step: :done, completed_steps: MapSet.new([:welcome, :locate_log])}
      assert State.advance(state) == state
    end
  end

  describe "previous/1" do
    test "at :welcome is a no-op" do
      state = %State{step: :welcome}
      assert State.previous(state) == state
    end

    test "moves back one step" do
      state = %State{step: :card_status, completed_steps: MapSet.new([:welcome, :locate_log])}
      prev = State.previous(state)

      assert prev.step == :locate_log
      # completed_steps is NOT cleared on backward nav
      assert prev.completed_steps == state.completed_steps
    end
  end

  describe "struct defaults" do
    test "defaults to the welcome step with empty state" do
      state = %State{step: :welcome}
      assert state.detected_path == nil
      assert state.manual_path == nil
      assert state.manual_path_error == nil
      assert MapSet.size(state.completed_steps) == 0
    end
  end
end
