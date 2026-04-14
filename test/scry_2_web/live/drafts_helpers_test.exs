defmodule Scry2Web.DraftsHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.DraftsHelpers

  describe "trophy?/1" do
    test "true when wins == 7" do
      assert DraftsHelpers.trophy?(%{wins: 7})
    end

    test "false otherwise" do
      refute DraftsHelpers.trophy?(%{wins: 6})
      refute DraftsHelpers.trophy?(%{wins: nil})
    end
  end

  describe "win_rate/1" do
    test "computes win rate from wins/losses" do
      assert_in_delta DraftsHelpers.win_rate(%{wins: 7, losses: 2}), 0.777, 0.001
    end

    test "nil when no games played" do
      assert DraftsHelpers.win_rate(%{wins: nil, losses: nil}) == nil
      assert DraftsHelpers.win_rate(%{wins: 0, losses: 0}) == nil
    end
  end

  describe "format_label/1" do
    test "converts format strings to human labels" do
      assert DraftsHelpers.format_label("quick_draft") == "Quick Draft"
      assert DraftsHelpers.format_label("premier_draft") == "Premier Draft"
      assert DraftsHelpers.format_label("traditional_draft") == "Traditional Draft"
      assert DraftsHelpers.format_label("unknown") == "Unknown"
      assert DraftsHelpers.format_label(nil) == "—"
    end
  end

  describe "group_pool_by_type/2" do
    test "groups cards by type using provided type lookup" do
      cards_by_arena_id = %{
        1 => %{type_line: "Creature — Wizard"},
        2 => %{type_line: "Instant"},
        3 => %{type_line: "Land"}
      }

      groups = DraftsHelpers.group_pool_by_type([1, 2, 3], cards_by_arena_id)

      assert Enum.find(groups, &(elem(&1, 0) == "Creatures")) != nil
      assert Enum.find(groups, &(elem(&1, 0) == "Instants & Sorceries")) != nil
      assert Enum.find(groups, &(elem(&1, 0) == "Lands")) != nil
    end

    test "unknown arena_ids are omitted" do
      groups = DraftsHelpers.group_pool_by_type([999], %{})
      assert groups == []
    end

    test "classifies Sorcery into Instants & Sorceries" do
      cards_by_arena_id = %{1 => %{type_line: "Sorcery"}}
      groups = DraftsHelpers.group_pool_by_type([1], cards_by_arena_id)
      assert Enum.find(groups, &(elem(&1, 0) == "Instants & Sorceries")) != nil
    end

    test "classifies Artifact into Artifacts & Enchantments" do
      cards_by_arena_id = %{1 => %{type_line: "Artifact"}}
      groups = DraftsHelpers.group_pool_by_type([1], cards_by_arena_id)
      assert Enum.find(groups, &(elem(&1, 0) == "Artifacts & Enchantments")) != nil
    end

    test "classifies Enchantment into Artifacts & Enchantments" do
      cards_by_arena_id = %{1 => %{type_line: "Enchantment — Aura"}}
      groups = DraftsHelpers.group_pool_by_type([1], cards_by_arena_id)
      assert Enum.find(groups, &(elem(&1, 0) == "Artifacts & Enchantments")) != nil
    end

    test "classifies unrecognized type_line into Other" do
      cards_by_arena_id = %{1 => %{type_line: "Planeswalker — Jace"}}
      groups = DraftsHelpers.group_pool_by_type([1], cards_by_arena_id)
      assert Enum.find(groups, &(elem(&1, 0) == "Other")) != nil
    end
  end

  describe "win_loss_label/2" do
    test "formats wins and losses" do
      assert DraftsHelpers.win_loss_label(7, 2) == "7–2"
    end

    test "uses 0 for nil values" do
      assert DraftsHelpers.win_loss_label(nil, nil) == "0–0"
    end
  end

  describe "draft_status_label/1" do
    test "Complete when completed_at is set" do
      assert DraftsHelpers.draft_status_label(%{completed_at: DateTime.utc_now()}) == "Complete"
    end

    test "In progress when completed_at is nil" do
      assert DraftsHelpers.draft_status_label(%{completed_at: nil}) == "In progress"
    end
  end

  describe "record_color_class/1" do
    test "emerald for win rate >= 55%" do
      assert DraftsHelpers.record_color_class(%{wins: 7, losses: 0}) == "text-success"
    end

    test "amber for 40-54%" do
      assert DraftsHelpers.record_color_class(%{wins: 4, losses: 6}) == "text-warning"
    end

    test "red for < 40%" do
      assert DraftsHelpers.record_color_class(%{wins: 1, losses: 9}) == "text-error"
    end

    test "muted for nil" do
      assert DraftsHelpers.record_color_class(%{wins: nil, losses: nil}) == "text-base-content/50"
    end
  end
end
