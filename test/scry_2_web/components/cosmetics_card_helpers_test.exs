defmodule Scry2Web.Components.CosmeticsCard.HelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.Components.CosmeticsCard.Helpers, as: H

  defp summary(available, owned) do
    %{available: available, owned: owned}
  end

  describe "has_data?/1" do
    test "true when any available count is non-zero" do
      assert H.has_data?(
               summary(
                 %{art_styles: 100, avatars: 0, pets: 0, sleeves: 0, emotes: 0, titles: 0},
                 %{art_styles: 0, avatars: 0, pets: 0, sleeves: 0, emotes: 0, titles: 0}
               )
             )
    end

    test "false when nil" do
      refute H.has_data?(nil)
    end

    test "false when available block is missing" do
      refute H.has_data?(%{owned: %{}})
    end

    test "false when every available count is zero (stale or pre-login read)" do
      refute H.has_data?(
               summary(
                 %{art_styles: 0, avatars: 0, pets: 0, sleeves: 0, emotes: 0, titles: 0},
                 %{art_styles: 0, avatars: 0, pets: 0, sleeves: 0, emotes: 0, titles: 0}
               )
             )
    end
  end

  describe "rows/1" do
    test "produces a row per category with owned, total, percent (when available > 0)" do
      rows =
        H.rows(
          summary(
            %{art_styles: 100, avatars: 50, pets: 20, sleeves: 200, emotes: 10, titles: 5},
            %{art_styles: 25, avatars: 10, pets: 4, sleeves: 50, emotes: 1, titles: 0}
          )
        )

      assert rows == [
               {"Alt arts", 25, 100, 25},
               {"Avatars", 10, 50, 20},
               {"Pets", 4, 20, 20},
               {"Sleeves", 50, 200, 25},
               {"Emotes", 1, 10, 10},
               {"Titles", 0, 5, 0}
             ]
    end

    test "drops categories whose available count is 0 (lazy-loaded stub)" do
      rows =
        H.rows(
          summary(
            %{art_styles: 100, avatars: 50, pets: 20, sleeves: 200, emotes: 10, titles: 0},
            %{art_styles: 25, avatars: 10, pets: 4, sleeves: 50, emotes: 1, titles: 0}
          )
        )

      labels = Enum.map(rows, fn {l, _, _, _} -> l end)
      assert "Titles" not in labels
      assert length(rows) == 5
    end

    test "all-zero summary produces an empty list" do
      rows =
        H.rows(
          summary(
            %{art_styles: 0, avatars: 0, pets: 0, sleeves: 0, emotes: 0, titles: 0},
            %{art_styles: 0, avatars: 0, pets: 0, sleeves: 0, emotes: 0, titles: 0}
          )
        )

      assert rows == []
    end

    test "missing category keys default to 0" do
      rows = H.rows(%{available: %{art_styles: 100}, owned: %{art_styles: 5}})

      [{"Alt arts", o, a, _} | _] = rows
      assert {o, a} == {5, 100}
    end

    test "nil → empty list" do
      assert H.rows(nil) == []
    end
  end

  describe "format_count/1" do
    test "comma-separates large integers" do
      assert H.format_count(14_592) == "14,592"
      assert H.format_count(1_000_000) == "1,000,000"
    end

    test "negative passes through with sign" do
      assert H.format_count(-1234) == "-1,234"
    end

    test "small integers untouched" do
      assert H.format_count(0) == "0"
      assert H.format_count(42) == "42"
    end
  end
end
