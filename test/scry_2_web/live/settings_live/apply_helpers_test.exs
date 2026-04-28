defmodule Scry2Web.SettingsLive.ApplyHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.SettingsLive.ApplyHelpers

  describe "visible_phases/0" do
    test "returns the rows the modal renders, in order" do
      assert ApplyHelpers.visible_phases() == [:downloading, :extracting, :handing_off]
    end
  end

  describe "apply_visible?/1" do
    test "returns false only for nil (idle)" do
      refute ApplyHelpers.apply_visible?(nil)
    end

    test "returns true for any non-nil phase" do
      for phase <- [:preparing, :downloading, :extracting, :handing_off, :done, :failed] do
        assert ApplyHelpers.apply_visible?(phase), "expected #{inspect(phase)} to be visible"
      end
    end
  end

  describe "apply_phase_label/1" do
    test "produces a label for every phase" do
      assert ApplyHelpers.apply_phase_label(:preparing) == "Preparing…"
      assert ApplyHelpers.apply_phase_label(:downloading) == "Downloading release"
      assert ApplyHelpers.apply_phase_label(:extracting) == "Extracting files"
      assert ApplyHelpers.apply_phase_label(:handing_off) == "Installing and restarting"
      assert ApplyHelpers.apply_phase_label(:done) == "Update staged. Restarting…"
      assert ApplyHelpers.apply_phase_label(:failed) == "Update failed"
    end

    test "returns empty string for nil" do
      assert ApplyHelpers.apply_phase_label(nil) == ""
    end
  end

  describe "phase_state/3" do
    test "every row is :pending when nothing is in flight" do
      for target <- ApplyHelpers.visible_phases() do
        assert ApplyHelpers.phase_state(target, nil, nil) == :pending
      end
    end

    test "earlier rows are :done, current row is :active, later rows are :pending" do
      assert ApplyHelpers.phase_state(:downloading, :extracting, nil) == :done
      assert ApplyHelpers.phase_state(:extracting, :extracting, nil) == :active
      assert ApplyHelpers.phase_state(:handing_off, :extracting, nil) == :pending
    end

    test "all rows are :done when overall phase is :done" do
      for target <- ApplyHelpers.visible_phases() do
        assert ApplyHelpers.phase_state(target, :done, nil) == :done
      end
    end

    test "the failed row is :failed; rows before are :done; rows after are :pending" do
      assert ApplyHelpers.phase_state(:downloading, :failed, :extracting) == :done
      assert ApplyHelpers.phase_state(:extracting, :failed, :extracting) == :failed
      assert ApplyHelpers.phase_state(:handing_off, :failed, :extracting) == :pending
    end
  end

  describe "apply_cancelable?/1" do
    test "true while pre-handoff" do
      assert ApplyHelpers.apply_cancelable?(:preparing)
      assert ApplyHelpers.apply_cancelable?(:downloading)
      assert ApplyHelpers.apply_cancelable?(:extracting)
    end

    test "false from handoff onward" do
      refute ApplyHelpers.apply_cancelable?(:handing_off)
      refute ApplyHelpers.apply_cancelable?(:done)
      refute ApplyHelpers.apply_cancelable?(:failed)
      refute ApplyHelpers.apply_cancelable?(nil)
    end
  end

  describe "phase_text_class/1" do
    test "produces a distinct class per state" do
      classes =
        Enum.map([:pending, :active, :done, :failed], &ApplyHelpers.phase_text_class/1)

      assert length(Enum.uniq(classes)) == 4
    end

    test "active class indicates the in-flight row" do
      assert ApplyHelpers.phase_text_class(:active) =~ "font-medium"
    end

    test "failed class indicates the error row" do
      assert ApplyHelpers.phase_text_class(:failed) =~ "text-error"
    end
  end

  describe "apply_error_label/1" do
    test "named atoms map to dedicated sentences" do
      assert ApplyHelpers.apply_error_label(:checksum_mismatch) =~ "checksum"
      assert ApplyHelpers.apply_error_label(:path_traversal) =~ "unsafe path"
      assert ApplyHelpers.apply_error_label(:spawn_failed) =~ "launch"
    end

    test "tagged tuples include the inner reason" do
      assert ApplyHelpers.apply_error_label({:download, :timeout}) ==
               "Download failed: timeout"

      assert ApplyHelpers.apply_error_label({:stage, :path_traversal}) ==
               "Archive rejected: path_traversal"
    end

    test "handoff errors hide the inner detail" do
      assert ApplyHelpers.apply_error_label({:handoff, :anything}) =~ "hand off"
    end

    test "unknown reasons get a generic prefix" do
      assert ApplyHelpers.apply_error_label(:weird_thing) =~ "Update failed"
      assert ApplyHelpers.apply_error_label({:wrapped, "detail"}) =~ "Update failed"
    end
  end
end
