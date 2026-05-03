defmodule Scry2.Console.DisplayHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2.Console.{Entry, Filter, DisplayHelpers}

  defp entry(overrides) do
    defaults = %{
      id: 1,
      timestamp: ~U[2026-04-05 14:23:45.123000Z],
      level: :info,
      component: :ingester,
      message: "Hello"
    }

    Entry.new(Map.merge(defaults, Map.new(overrides)))
  end

  describe "known_components/0" do
    test "returns app components first, then framework components" do
      components = DisplayHelpers.known_components()

      assert components == [
               :watcher,
               :parser,
               :ingester,
               :importer,
               :http,
               :live_state,
               :system,
               :phoenix,
               :ecto,
               :live_view
             ]
    end

    test "app and framework accessors reflect the split" do
      assert DisplayHelpers.app_components() == [
               :watcher,
               :parser,
               :ingester,
               :importer,
               :http,
               :live_state,
               :system
             ]

      assert DisplayHelpers.framework_components() == [:phoenix, :ecto, :live_view]
    end
  end

  describe "format_timestamp/1" do
    test "formats HH:MM:SS.mmm" do
      assert DisplayHelpers.format_timestamp(~U[2026-04-05 14:23:45.123000Z]) == "14:23:45.123"
    end

    test "zero-pads single digit fields" do
      assert DisplayHelpers.format_timestamp(~U[2026-04-05 04:03:02.001000Z]) == "04:03:02.001"
    end
  end

  describe "level_color/1" do
    test "returns the right class for every level" do
      assert DisplayHelpers.level_color(:error) == "text-error"
      assert DisplayHelpers.level_color(:warning) == "text-warning"
      assert DisplayHelpers.level_color(:info) == "text-info"
      assert DisplayHelpers.level_color(:debug) == "text-base-content/60"
    end
  end

  describe "component_label/1 and component_badge_class/1" do
    test "component_label converts atoms to strings" do
      assert DisplayHelpers.component_label(:ingester) == "ingester"
      assert DisplayHelpers.component_label(nil) == "system"
    end

    test "component_badge_class returns a valid daisy badge class" do
      class = DisplayHelpers.component_badge_class(:ingester)

      assert class in ~w(badge-primary badge-secondary badge-accent badge-info badge-success badge-warning)
    end

    test "component_badge_class is deterministic for the same atom" do
      assert DisplayHelpers.component_badge_class(:watcher) ==
               DisplayHelpers.component_badge_class(:watcher)
    end

    test "component_badge_class returns badge-ghost for nil" do
      assert DisplayHelpers.component_badge_class(nil) == "badge-ghost"
    end
  end

  describe "format_line/1 and format_lines/1" do
    test "format_line renders timestamp + level + component + message" do
      line = DisplayHelpers.format_line(entry(%{message: "foo"}))
      assert line == "[14:23:45.123] [info] [ingester] foo"
    end

    test "format_lines returns empty string for empty list" do
      assert DisplayHelpers.format_lines([]) == ""
    end

    test "format_lines reverses newest-first entries to chronological order" do
      e1 = entry(%{id: 1, message: "first", timestamp: ~U[2026-04-05 14:00:00Z]})
      e2 = entry(%{id: 2, message: "second", timestamp: ~U[2026-04-05 14:00:01Z]})
      e3 = entry(%{id: 3, message: "third", timestamp: ~U[2026-04-05 14:00:02Z]})

      # Buffer stores newest-first.
      newest_first = [e3, e2, e1]

      output = DisplayHelpers.format_lines(newest_first)

      lines = String.split(output, "\n")
      assert length(lines) == 3
      assert Enum.at(lines, 0) =~ "first"
      assert Enum.at(lines, 2) =~ "third"
    end
  end

  describe "chip_state_class/2" do
    test "returns active when component is :show" do
      filter = %Filter{components: %{ingester: :show}, default_component: :show}
      assert DisplayHelpers.chip_state_class(filter, :ingester) == "console-chip-active"
    end

    test "returns inactive when component is :hide" do
      filter = %Filter{components: %{ecto: :hide}, default_component: :show}
      assert DisplayHelpers.chip_state_class(filter, :ecto) == "console-chip-inactive"
    end

    test "falls back to default_component when component not set" do
      filter = %Filter{components: %{}, default_component: :hide}
      assert DisplayHelpers.chip_state_class(filter, :missing) == "console-chip-inactive"
    end
  end

  describe "level_button_class/2" do
    test "returns btn-active when levels match" do
      filter = %Filter{level: :warning}
      assert DisplayHelpers.level_button_class(filter, :warning) == "btn-active"
    end

    test "returns empty string otherwise" do
      filter = %Filter{level: :info}
      assert DisplayHelpers.level_button_class(filter, :error) == ""
    end
  end

  describe "entry_search_text/1" do
    test "lowercases the message" do
      assert DisplayHelpers.entry_search_text(entry(%{message: "Hello WORLD"})) == "hello world"
    end
  end

  describe "pause_button_label/1" do
    test "true -> resume, false -> pause" do
      assert DisplayHelpers.pause_button_label(true) == "resume"
      assert DisplayHelpers.pause_button_label(false) == "pause"
    end
  end

  describe "only_search_changed?/2" do
    test "true when only search differs" do
      a = Filter.new_with_defaults()
      b = %{a | search: "foo"}
      assert DisplayHelpers.only_search_changed?(a, b)
    end

    test "false when level also differs" do
      a = Filter.new_with_defaults()
      b = %{a | search: "foo", level: :error}
      refute DisplayHelpers.only_search_changed?(a, b)
    end

    test "false when searches are equal" do
      a = Filter.new_with_defaults()
      refute DisplayHelpers.only_search_changed?(a, a)
    end
  end
end
