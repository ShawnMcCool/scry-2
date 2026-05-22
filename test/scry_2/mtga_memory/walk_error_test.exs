defmodule Scry2.MtgaMemory.WalkErrorTest do
  use ExUnit.Case, async: true

  alias Scry2.MtgaMemory.WalkError

  describe "translate/1" do
    test "translates known walker failure atoms to player-language strings" do
      cases = [
        {:mono_dll_not_found, "Couldn't find MTGA's runtime module"},
        {:mono_dll_read_failed, "MTGA's runtime module wouldn't open for reading"},
        {:root_domain_not_found, "Couldn't enter MTGA's runtime"},
        {:chain_failed, "Couldn't trace the pointer chain"}
      ]

      for {atom, expected_phrase} <- cases do
        assert WalkError.translate(atom) =~ expected_phrase,
               "expected translation of #{inspect(atom)} to contain #{inspect(expected_phrase)}"
      end
    end

    test "translates tagged-tuple errors with the class/assembly name" do
      assert WalkError.translate({:assembly_not_found, "Core"}) =~ "Core"
      assert WalkError.translate({:class_not_found, "InventoryManager"}) =~ "InventoryManager"
      assert WalkError.translate({:class_read_failed, "PlayerCards"}) =~ "PlayerCards"
    end

    test "falls back to a generic message for unknown shapes" do
      generic = WalkError.translate(:something_we_havent_seen)
      assert is_binary(generic)
      assert generic =~ "Memory reader" or generic =~ "Diagnostics"
    end

    test "tolerates string error reasons by passing them through" do
      assert WalkError.translate("verify took too long") =~ "took too long"
    end
  end

  describe "shared_chain?/1" do
    test "true for failures in the shared discovery base (every walk would hit them)" do
      assert WalkError.shared_chain?(:mono_dll_not_found)
      assert WalkError.shared_chain?(:mono_dll_read_failed)
      assert WalkError.shared_chain?(:root_domain_not_found)
    end

    test "false for walk-specific failures" do
      refute WalkError.shared_chain?({:class_not_found, "InventoryManager"})
      refute WalkError.shared_chain?(:chain_failed)
    end
  end
end
