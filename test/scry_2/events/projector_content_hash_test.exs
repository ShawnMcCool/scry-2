defmodule Scry2.Events.ProjectorContentHashTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.ProjectorRegistry

  describe "content_hash/0 injected by Projector macro" do
    test "every registered projector exposes content_hash/0" do
      for mod <- ProjectorRegistry.all() do
        # Ensure the module is loaded before calling function_exported?/3 —
        # async tests run before the application starts, so modules may not
        # yet be loaded into the BEAM.
        Code.ensure_loaded!(mod)

        assert function_exported?(mod, :content_hash, 0),
               "#{inspect(mod)} should export content_hash/0"
      end
    end

    test "every projector hash is a non-empty string" do
      for mod <- ProjectorRegistry.all() do
        hash = mod.content_hash()
        assert is_binary(hash), "#{inspect(mod)} hash should be a string"
        assert String.length(hash) > 0, "#{inspect(mod)} hash should not be empty"
      end
    end

    test "every projector hash is stable across calls" do
      for mod <- ProjectorRegistry.all() do
        assert mod.content_hash() == mod.content_hash(),
               "#{inspect(mod)} hash should be deterministic"
      end
    end

    test "different projectors have different hashes" do
      hashes =
        ProjectorRegistry.all()
        |> Enum.map(& &1.content_hash())
        |> Enum.uniq()

      assert length(hashes) == length(ProjectorRegistry.all()),
             "each projector should have a unique hash"
    end
  end
end
