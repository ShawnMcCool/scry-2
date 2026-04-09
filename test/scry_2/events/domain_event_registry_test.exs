defmodule Scry2.Events.DomainEventRegistryTest do
  use ExUnit.Case, async: true

  alias Scry2.Events

  describe "slug_to_module registry" do
    test "every registered module implements from_payload/1 and returns the correct struct" do
      for {slug, module} <- Events.__slug_to_module__() do
        result = module.from_payload(%{})

        assert is_struct(result),
               "#{module}.from_payload(%{}) returned #{inspect(result)}, expected a struct (slug: #{slug})"
      end
    end
  end
end
