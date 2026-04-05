defmodule Scry2Web.CardsHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2.Cards.Card
  alias Scry2Web.CardsHelpers, as: H

  describe "set_code/1" do
    test "returns the set code when preloaded" do
      card = %Card{set: %{code: "LCI"}}
      assert H.set_code(card) == "LCI"
    end

    test "returns — when set is not loaded" do
      assert H.set_code(%Card{}) == "—"
    end
  end

  describe "rarity_class/1" do
    test "maps each rarity to a distinct daisyUI class" do
      assert H.rarity_class("mythic") == "badge-warning"
      assert H.rarity_class("rare") == "badge-accent"
      assert H.rarity_class("uncommon") == "badge-info"
      assert H.rarity_class("common") == "badge-ghost"
    end

    test "falls back to ghost for unknown rarities" do
      assert H.rarity_class(nil) == "badge-ghost"
      assert H.rarity_class("land") == "badge-ghost"
    end
  end

  describe "color_identity_label/1" do
    test "returns Colorless for nil and empty strings" do
      assert H.color_identity_label(nil) == "Colorless"
      assert H.color_identity_label("") == "Colorless"
    end

    test "returns the identity string verbatim otherwise" do
      assert H.color_identity_label("WU") == "WU"
    end
  end

  describe "coerce_filters/1" do
    test "blanks empty strings to nil" do
      filters = H.coerce_filters(%{"name_like" => "", "rarity" => "rare"})

      assert filters.name_like == nil
      assert filters.rarity == "rare"
    end

    test "returns nil values for missing keys" do
      filters = H.coerce_filters(%{})

      assert filters == %{name_like: nil, rarity: nil, set_code: nil}
    end
  end

  describe "filter_params_to_query/1" do
    test "drops blank entries" do
      query = H.filter_params_to_query(%{"name_like" => "bolt", "rarity" => ""})
      assert query == %{"name_like" => "bolt"}
    end
  end
end
