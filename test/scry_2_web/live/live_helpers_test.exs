defmodule Scry2Web.LiveHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.LiveHelpers, as: H

  describe "format_datetime/1" do
    test "returns — for nil" do
      assert H.format_datetime(nil) == "—"
    end

    test "formats a UTC datetime as YYYY-MM-DD HH:MM" do
      datetime = ~U[2026-04-05 07:09:00Z]
      assert H.format_datetime(datetime) == "2026-04-05 07:09"
    end
  end

  describe "format_label/1" do
    test "title-cases snake_case format strings" do
      assert H.format_label("premier_draft") == "Premier Draft"
      assert H.format_label("traditional_draft") == "Traditional Draft"
      assert H.format_label("sealed") == "Sealed"
    end

    test "returns — for nil" do
      assert H.format_label(nil) == "—"
    end
  end

  describe "format_category/1" do
    test "Limited format_type maps to :limited" do
      assert H.format_category("Limited") == :limited
    end

    test "Constructed and Traditional both map to :constructed" do
      # BO1 vs BO3 is already a separate filter dimension on the matches page,
      # so Traditional (BO3 ranked) collapses into Constructed.
      assert H.format_category("Constructed") == :constructed
      assert H.format_category("Traditional") == :constructed
    end

    test "nil or unrecognized format_type maps to :other" do
      assert H.format_category(nil) == :other
      assert H.format_category("") == :other
      assert H.format_category("Bogus") == :other
    end
  end

  describe "category_label/1" do
    test "renders human labels for known categories" do
      assert H.category_label(:limited) == "Limited"
      assert H.category_label(:constructed) == "Constructed"
      assert H.category_label(:other) == "Other"
    end
  end

  describe "winrate period helpers" do
    test "default period is '2w'" do
      assert H.winrate_default_period() == "2w"
    end

    test "winrate_period_options returns all buckets including 3d/1w/2w/1m/3m/all" do
      slugs = H.winrate_period_options() |> Enum.map(fn {s, _} -> s end)
      assert "3d" in slugs
      assert "1w" in slugs
      assert "2w" in slugs
      assert "1m" in slugs
      assert "3m" in slugs
      assert "all" in slugs
    end

    test "winrate_period_to_days maps slugs correctly" do
      assert H.winrate_period_to_days("3d") == 3
      assert H.winrate_period_to_days("1w") == 7
      assert H.winrate_period_to_days("2w") == 14
      assert H.winrate_period_to_days("1m") == 30
      assert H.winrate_period_to_days("3m") == 90
      assert H.winrate_period_to_days("all") == nil
    end

    test "winrate_period_to_days falls back to default for nil/unknown" do
      assert H.winrate_period_to_days(nil) == 14
      assert H.winrate_period_to_days("garbage") == 14
    end

    test "winrate_period_or_default returns valid slug as-is" do
      assert H.winrate_period_or_default("3m") == "3m"
    end

    test "winrate_period_or_default returns default for nil/unknown" do
      assert H.winrate_period_or_default(nil) == "2w"
      assert H.winrate_period_or_default("bogus") == "2w"
    end
  end

  describe "category_slug/1" do
    test "round-trips category atom to URL slug and back" do
      for category <- [:limited, :constructed, :other] do
        slug = H.category_slug(category)
        assert is_binary(slug)
        assert H.category_from_slug(slug) == category
      end
    end

    test "category_from_slug returns nil for unknown values" do
      assert H.category_from_slug(nil) == nil
      assert H.category_from_slug("") == nil
      assert H.category_from_slug("bogus") == nil
    end
  end
end
