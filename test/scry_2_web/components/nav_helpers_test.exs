defmodule Scry2Web.NavHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.NavHelpers

  describe "items/0" do
    test "returns 8 main-nav items" do
      assert length(NavHelpers.items()) == 8
    end

    test "every item has a path starting with /" do
      assert Enum.all?(NavHelpers.items(), &String.starts_with?(&1.path, "/"))
    end

    test "every item has a non-empty label" do
      assert Enum.all?(NavHelpers.items(), &(is_binary(&1.label) and &1.label != ""))
    end

    test "paths are unique" do
      paths = Enum.map(NavHelpers.items(), & &1.path)
      assert paths == Enum.uniq(paths)
    end

    test "ordering matches the visible nav (matches first, collection last)" do
      paths = Enum.map(NavHelpers.items(), & &1.path)
      assert hd(paths) == "/matches"
      assert List.last(paths) == "/collection"
    end
  end

  describe "active?/2" do
    test "returns false when current_path is nil" do
      refute NavHelpers.active?(nil, "/matches")
    end

    test "returns false for item_path '/' regardless of current_path" do
      refute NavHelpers.active?("/matches", "/")
      refute NavHelpers.active?("/", "/")
    end

    test "returns true for an exact path match" do
      assert NavHelpers.active?("/matches", "/matches")
    end

    test "returns true for a child path" do
      assert NavHelpers.active?("/matches/abc-123", "/matches")
      assert NavHelpers.active?("/decks/42", "/decks")
    end

    test "returns false for an unrelated path" do
      refute NavHelpers.active?("/decks", "/matches")
      refute NavHelpers.active?("/cards", "/collection")
    end
  end

  describe "gear_indicator/1" do
    test "returns :badge when an update is available" do
      assert %{kind: :badge, label: "v0.38.0"} =
               NavHelpers.gear_indicator(%{
                 summary: %{status: :update_available, version: "0.38.0"}
               })
    end

    test "returns :none when up to date" do
      assert %{kind: :none} =
               NavHelpers.gear_indicator(%{
                 summary: %{status: :up_to_date, version: "0.38.0"}
               })
    end

    test "returns :none when there is no data" do
      assert %{kind: :none} =
               NavHelpers.gear_indicator(%{summary: %{status: :no_data}})
    end

    test "returns :none for any other summary status" do
      assert %{kind: :none} =
               NavHelpers.gear_indicator(%{
                 summary: %{status: :ahead_of_release, version: "9.9.9"}
               })

      assert %{kind: :none} =
               NavHelpers.gear_indicator(%{summary: %{status: :invalid}})
    end

    test "returns :none when summary is missing entirely" do
      assert %{kind: :none} = NavHelpers.gear_indicator(%{})
    end

    test "returns :none when version is missing despite :update_available status" do
      assert %{kind: :none} =
               NavHelpers.gear_indicator(%{
                 summary: %{status: :update_available, version: nil}
               })
    end
  end
end
