defmodule Scry2Web.SidebarNavTest do
  use ExUnit.Case, async: true

  alias Scry2Web.SidebarNav

  describe "sections/0" do
    test "the first section has no label (general tools)" do
      [first | _] = SidebarNav.sections()
      assert first.label == nil
    end

    test "Cards is the only item in the first (general tools) section" do
      [first | _] = SidebarNav.sections()
      assert Enum.map(first.items, & &1.path) == ["/cards"]
    end

    test "all subsequent sections have labels" do
      [_first | rest] = SidebarNav.sections()
      labels = Enum.map(rest, & &1.label)
      assert "Play" in labels
      assert "Profile" in labels
      assert "Economy" in labels
      assert "Collection" in labels
      refute Enum.any?(labels, &is_nil/1)
    end

    test "every item has a path, label, and icon" do
      for section <- SidebarNav.sections(),
          item <- section.items do
        assert is_binary(item.path)
        assert is_binary(item.label)
        assert is_binary(item.icon)
        assert String.starts_with?(item.icon, "hero-")
      end
    end
  end

  describe "items/0" do
    test "returns all 10 items in section order" do
      paths = SidebarNav.items() |> Enum.map(& &1.path)

      assert paths == [
               "/cards",
               "/matches",
               "/decks",
               "/netdecks",
               "/drafts",
               "/player",
               "/ranks",
               "/economy",
               "/collection"
             ]
    end
  end

  describe "active?/2" do
    test "is true on exact match" do
      assert SidebarNav.active?("/matches", "/matches")
    end

    test "is true on nested path" do
      assert SidebarNav.active?("/collection/sets/BLB", "/collection")
    end

    test "is false on disjoint paths" do
      refute SidebarNav.active?("/matches", "/decks")
    end

    test "is false when current_path is nil" do
      refute SidebarNav.active?(nil, "/matches")
    end

    test "never lights up nav items for the home route" do
      refute SidebarNav.active?("/", "/cards")
    end
  end
end
