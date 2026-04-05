defmodule Scry2.Console.FilterTest do
  use ExUnit.Case, async: true

  alias Scry2.Console.{Entry, Filter}

  defp entry(overrides) do
    defaults = %{
      id: 1,
      timestamp: DateTime.utc_now(),
      level: :info,
      component: :ingester,
      message: "Default message"
    }

    Entry.new(Map.merge(defaults, Map.new(overrides)))
  end

  describe "new_with_defaults/0" do
    test "seeds app components as :show and framework as :hide" do
      filter = Filter.new_with_defaults()

      assert filter.level == :info
      assert filter.default_component == :show
      assert filter.search == ""

      for c <- [:watcher, :parser, :ingester, :importer, :http, :system] do
        assert Map.get(filter.components, c) == :show, "expected #{c} visible"
      end

      for c <- [:phoenix, :ecto, :live_view] do
        assert Map.get(filter.components, c) == :hide, "expected #{c} hidden"
      end
    end
  end

  describe "matches?/2 — level floor" do
    test "info floor passes info and above but not debug" do
      filter = Filter.new_with_defaults()
      assert Filter.matches?(entry(%{level: :info}), filter)
      assert Filter.matches?(entry(%{level: :warning}), filter)
      assert Filter.matches?(entry(%{level: :error}), filter)
      refute Filter.matches?(entry(%{level: :debug}), filter)
    end

    test "error floor blocks info and warning" do
      filter = %{Filter.new_with_defaults() | level: :error}
      refute Filter.matches?(entry(%{level: :info}), filter)
      refute Filter.matches?(entry(%{level: :warning}), filter)
      assert Filter.matches?(entry(%{level: :error}), filter)
    end
  end

  describe "matches?/2 — component visibility" do
    test "framework components are hidden by default" do
      filter = Filter.new_with_defaults()
      refute Filter.matches?(entry(%{component: :ecto}), filter)
      refute Filter.matches?(entry(%{component: :phoenix}), filter)
      assert Filter.matches?(entry(%{component: :ingester}), filter)
    end

    test "unknown components fall back to default_component" do
      default_show = %{Filter.new_with_defaults() | default_component: :show}
      assert Filter.matches?(entry(%{component: :brand_new_component}), default_show)

      default_hide = %{Filter.new_with_defaults() | default_component: :hide, components: %{}}
      refute Filter.matches?(entry(%{component: :brand_new_component}), default_hide)
    end
  end

  describe "matches?/2 — search" do
    test "case-insensitive substring match" do
      filter = %{Filter.new_with_defaults() | search: "HELLO"}
      assert Filter.matches?(entry(%{message: "say hello world"}), filter)
      refute Filter.matches?(entry(%{message: "no match"}), filter)
    end

    test "empty search always passes" do
      filter = Filter.new_with_defaults()
      assert Filter.matches?(entry(%{message: "anything"}), filter)
    end
  end

  describe "toggle_component/2" do
    test "flips :show → :hide and back" do
      filter = Filter.new_with_defaults()
      flipped = Filter.toggle_component(filter, :ingester)
      assert flipped.components[:ingester] == :hide
      assert Filter.toggle_component(flipped, :ingester).components[:ingester] == :show
    end

    test "unknown components use default_component as starting point" do
      filter = %{Filter.new_with_defaults() | default_component: :show, components: %{}}
      flipped = Filter.toggle_component(filter, :brand_new)
      assert flipped.components[:brand_new] == :hide
    end
  end

  describe "solo_component/2 and mute_component/2" do
    test "solo makes only the named component visible" do
      filter = Filter.new_with_defaults()
      soloed = Filter.solo_component(filter, :watcher)

      assert soloed.components[:watcher] == :show

      for c <- [:parser, :ingester, :importer, :http, :system, :phoenix, :ecto, :live_view] do
        assert soloed.components[c] == :hide, "expected #{c} hidden after solo"
      end
    end

    test "mute makes the named component invisible, everything else visible" do
      filter = Filter.new_with_defaults()
      muted = Filter.mute_component(filter, :ecto)

      assert muted.components[:ecto] == :hide

      for c <- [:watcher, :parser, :ingester, :importer, :http, :system, :phoenix, :live_view] do
        assert muted.components[c] == :show, "expected #{c} visible after mute"
      end
    end
  end

  describe "to_persistable/1 ↔ from_persistable/1 round trip" do
    test "preserves level, components, default_component, and search" do
      original = %{Filter.new_with_defaults() | level: :warning, search: "foo"}
      persisted = Filter.to_persistable(original)

      # All values are strings (JSON-safe).
      assert is_binary(persisted["level"])
      assert Enum.all?(persisted["components"], fn {k, v} -> is_binary(k) and is_binary(v) end)

      restored = Filter.from_persistable(persisted)
      assert restored == original
    end

    test "from_persistable ignores unknown visibility and falls back" do
      bad = %{"level" => "info", "search" => "", "components" => %{"ecto" => "totally_bogus"}}
      filter = Filter.from_persistable(bad)
      # safe_visibility_atom default is :show
      assert filter.components[:ecto] == :show
    end

    test "from_persistable handles non-map input without crashing" do
      assert %Filter{} = Filter.from_persistable(nil)
      assert %Filter{} = Filter.from_persistable("junk")
      assert %Filter{} = Filter.from_persistable(42)
    end

    test "from_persistable tolerates missing fields" do
      filter = Filter.from_persistable(%{})
      assert filter.level == :info
      assert filter.search == ""
    end
  end
end
