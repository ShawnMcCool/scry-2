defmodule Scry2Web.Collection.BuildChangeBannerTest do
  use ExUnit.Case, async: true

  alias Scry2Web.Collection.BuildChangeBanner

  describe "translate_error/1" do
    test "translates known walker failure atoms to player-language strings" do
      cases = [
        {:mono_dll_not_found, "Couldn't find MTGA's runtime module"},
        {:mono_dll_read_failed, "MTGA's runtime module wouldn't open for reading"},
        {:root_domain_not_found, "Couldn't enter MTGA's runtime"},
        {:chain_failed, "Couldn't trace the pointer chain"}
      ]

      for {atom, expected_phrase} <- cases do
        assert BuildChangeBanner.translate_error(atom) =~ expected_phrase,
               "expected translation of #{inspect(atom)} to contain #{inspect(expected_phrase)}"
      end
    end

    test "translates tagged-tuple errors with the class/assembly name" do
      assert BuildChangeBanner.translate_error({:assembly_not_found, "Core"}) =~ "Core"

      assert BuildChangeBanner.translate_error({:class_not_found, "InventoryManager"}) =~
               "InventoryManager"

      assert BuildChangeBanner.translate_error({:class_read_failed, "PlayerCards"}) =~
               "PlayerCards"
    end

    test "falls back to a generic message for unknown shapes" do
      generic = BuildChangeBanner.translate_error(:something_we_havent_seen)
      assert is_binary(generic)
      assert generic =~ "Memory reader" or generic =~ "Diagnostics"
    end

    test "tolerates string error reasons by passing them through" do
      assert BuildChangeBanner.translate_error("verify took too long") =~ "took too long"
    end
  end
end
