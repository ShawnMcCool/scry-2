defmodule Scry2Web.DeckRendering.CompositionPrefsTest do
  use ExUnit.Case, async: true

  alias Scry2Web.DeckRendering.CompositionPrefs

  describe "defaults" do
    test "images on top, text grouped by type, images grouped by mana value, both visible" do
      prefs = %CompositionPrefs{}

      assert prefs.display_mode == :both
      assert prefs.top == :images
      assert prefs.text_group_by == :type
      assert prefs.images_group_by == :mana_value
    end
  end

  describe "parse/1" do
    test "parses a stored string map into a prefs struct" do
      stored = %{
        "display_mode" => "text",
        "top" => "text",
        "text_group_by" => "mana_value",
        "images_group_by" => "type"
      }

      assert CompositionPrefs.parse(stored) == %CompositionPrefs{
               display_mode: :text,
               top: :text,
               text_group_by: :mana_value,
               images_group_by: :type
             }
    end

    test "round-trips through to_stored/1" do
      prefs = %CompositionPrefs{display_mode: :images, top: :text, text_group_by: :mana_value}

      assert prefs |> CompositionPrefs.to_stored() |> CompositionPrefs.parse() == prefs
    end

    test "yields defaults for nil or non-map input" do
      assert CompositionPrefs.parse(nil) == %CompositionPrefs{}
      assert CompositionPrefs.parse("grid") == %CompositionPrefs{}
      assert CompositionPrefs.parse(42) == %CompositionPrefs{}
    end

    test "keeps defaults for missing, unknown, or invalid fields" do
      stored = %{"display_mode" => "text", "top" => "sideways", "surprise" => "yes"}

      assert CompositionPrefs.parse(stored) == %CompositionPrefs{display_mode: :text}
    end
  end

  describe "put/3" do
    test "sets each field from event strings" do
      prefs = %CompositionPrefs{}

      assert CompositionPrefs.put(prefs, "display_mode", "text").display_mode == :text
      assert CompositionPrefs.put(prefs, "top", "text").top == :text

      assert CompositionPrefs.put(prefs, "text_group_by", "mana_value").text_group_by ==
               :mana_value

      assert CompositionPrefs.put(prefs, "images_group_by", "type").images_group_by == :type
    end

    test "ignores unknown fields and values" do
      prefs = %CompositionPrefs{}

      assert CompositionPrefs.put(prefs, "surprise", "text") == prefs
      assert CompositionPrefs.put(prefs, "display_mode", "grid") == prefs
      assert CompositionPrefs.put(prefs, "display_mode", nil) == prefs
      assert CompositionPrefs.put(prefs, "top", :images) == prefs
    end
  end

  describe "visible_displays/1" do
    test "projects display_mode onto the ViewSpec.display vocabulary" do
      assert CompositionPrefs.visible_displays(%CompositionPrefs{display_mode: :text}) == [:text]

      assert CompositionPrefs.visible_displays(%CompositionPrefs{display_mode: :images}) ==
               [:images]

      assert CompositionPrefs.visible_displays(%CompositionPrefs{display_mode: :both}) ==
               [:text, :images]
    end
  end

  describe "section_order/1" do
    test "orders both visible sections top-first" do
      assert CompositionPrefs.section_order(%CompositionPrefs{top: :images}) == [:images, :text]
      assert CompositionPrefs.section_order(%CompositionPrefs{top: :text}) == [:text, :images]
    end

    test "a single-display mode yields only that section regardless of top" do
      assert CompositionPrefs.section_order(%CompositionPrefs{display_mode: :text, top: :images}) ==
               [:text]

      assert CompositionPrefs.section_order(%CompositionPrefs{display_mode: :images, top: :text}) ==
               [:images]
    end
  end

  describe "flipped_top/1" do
    test "flips which section renders first" do
      assert CompositionPrefs.flipped_top(%CompositionPrefs{top: :images}) == :text
      assert CompositionPrefs.flipped_top(%CompositionPrefs{top: :text}) == :images
    end
  end
end
