defmodule Scry2.SetupFlowTest do
  use Scry2.DataCase, async: false

  @moduletag :tmp_dir

  alias Scry2.Settings
  alias Scry2.SetupFlow
  alias Scry2.SetupFlow.State

  describe "required?/0" do
    test "true when nothing is completed and the derived signals aren't ready" do
      # In the test sandbox: no player log, no cards, no events — Health.setup_ready?
      # returns false. No setup_completed_at set.
      assert SetupFlow.required?()
    end

    test "false when mark_completed!/0 has been called" do
      :ok = SetupFlow.mark_completed!()
      refute SetupFlow.required?()
    end

    test "true again after reset!/0" do
      :ok = SetupFlow.mark_completed!()
      refute SetupFlow.required?()

      :ok = SetupFlow.reset!()
      assert SetupFlow.required?()
    end
  end

  describe "completed_persisted?/0" do
    test "false when Settings has no entry" do
      refute SetupFlow.completed_persisted?()
    end

    test "true when Settings has a non-empty value" do
      Settings.put!("setup_completed_at", "2026-04-11T12:00:00Z")
      assert SetupFlow.completed_persisted?()
    end

    test "false when Settings value is nil" do
      Settings.put!("setup_completed_at", nil)
      refute SetupFlow.completed_persisted?()
    end

    test "false when Settings value is empty string" do
      Settings.put!("setup_completed_at", "")
      refute SetupFlow.completed_persisted?()
    end
  end

  describe "persist_player_log_path!/1" do
    test "returns error when the path is not a regular file", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "nonexistent.log")
      assert {:error, :not_a_file} = SetupFlow.persist_player_log_path!(missing)
      refute Settings.get("mtga_logs_player_log_path")
    end

    test "writes to Settings when the file exists", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "Player.log")
      File.write!(path, "")

      assert {:ok, ^path} = SetupFlow.persist_player_log_path!(path)
      assert Settings.get("mtga_logs_player_log_path") == path
    end

    test "expands user paths", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "Player.log")
      File.write!(path, "")

      # Reach into the tmp_dir via its absolute path, which Path.expand
      # leaves unchanged — but still proves the call goes through expand.
      assert {:ok, persisted} = SetupFlow.persist_player_log_path!(path)
      assert persisted == Path.expand(path)
    end
  end

  describe "initial_state/0" do
    test "returns a welcome state with completed_steps empty" do
      state = SetupFlow.initial_state()
      assert %State{step: :welcome} = state
      assert MapSet.size(state.completed_steps) == 0
    end
  end

  describe "advance/1 and previous/1 (delegates)" do
    test "advance progresses steps" do
      state = %State{step: :welcome}
      assert %State{step: :locate_log} = SetupFlow.advance(state)
    end

    test "previous moves backwards" do
      state = %State{step: :card_status}
      assert %State{step: :locate_log} = SetupFlow.previous(state)
    end
  end
end
