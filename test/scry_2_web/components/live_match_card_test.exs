defmodule Scry2Web.Components.LiveMatchCardTest do
  use ExUnit.Case, async: true
  alias Scry2Web.Components.LiveMatchCard

  describe "view_model/1" do
    test "nil tick → not active, empty fields" do
      vm = LiveMatchCard.view_model(nil)

      assert vm.active? == false
      assert vm.opponent_name == nil
      assert vm.local_name == nil
      assert vm.opponent_rank == nil
      assert vm.local_rank == nil
      assert vm.game_number == nil
      assert vm.local_commander_arena_ids == []
      assert vm.opponent_commander_arena_ids == []
    end

    test "valid tick → active, all fields populated" do
      tick = %{
        local: player_info(screen_name: "Shawn", ranking_class: 4, ranking_tier: 2),
        opponent: player_info(screen_name: "RivalPlayer", ranking_class: 5, ranking_tier: 3),
        match_id: "abc-123",
        format: 1,
        variant: 0,
        session_type: 0,
        current_game_number: 2,
        match_state: 1,
        local_player_seat_id: 1,
        is_practice_game: false,
        is_private_game: false,
        reader_version: "rust:test"
      }

      vm = LiveMatchCard.view_model(tick)

      assert vm.active? == true
      assert vm.opponent_name == "RivalPlayer"
      assert vm.local_name == "Shawn"
      assert vm.opponent_rank == "Diamond 3"
      assert vm.local_rank == "Platinum 2"
      assert vm.game_number == 2
    end

    test "placeholder screen names ('Opponent', 'Local Player') are filtered to nil" do
      tick =
        match_info(
          local: player_info(screen_name: "Local Player"),
          opponent: player_info(screen_name: "Opponent")
        )

      vm = LiveMatchCard.view_model(tick)

      assert vm.opponent_name == nil
      assert vm.local_name == nil
    end

    test "empty screen name strings are filtered to nil" do
      tick =
        match_info(
          local: player_info(screen_name: ""),
          opponent: player_info(screen_name: nil)
        )

      vm = LiveMatchCard.view_model(tick)

      assert vm.opponent_name == nil
      assert vm.local_name == nil
    end

    test "ranking_class = 0 (None) yields nil rank label" do
      tick =
        match_info(
          local: player_info(ranking_class: 0, ranking_tier: 0),
          opponent: player_info(ranking_class: 0, ranking_tier: 0)
        )

      vm = LiveMatchCard.view_model(tick)

      assert vm.local_rank == nil
      assert vm.opponent_rank == nil
    end

    test "Mythic class with placement renders as 'Mythic #42'" do
      tick =
        match_info(
          opponent:
            player_info(
              ranking_class: 6,
              ranking_tier: 1,
              mythic_percentile: 0,
              mythic_placement: 42
            )
        )

      vm = LiveMatchCard.view_model(tick)

      assert vm.opponent_rank == "Mythic #42"
    end

    test "Mythic class with percentile only renders as 'Mythic 12%'" do
      tick =
        match_info(
          opponent:
            player_info(
              ranking_class: 6,
              ranking_tier: 1,
              mythic_percentile: 12,
              mythic_placement: 0
            )
        )

      vm = LiveMatchCard.view_model(tick)

      assert vm.opponent_rank == "Mythic 12%"
    end

    test "Mythic class with neither percentile nor placement renders as just 'Mythic'" do
      tick =
        match_info(
          opponent:
            player_info(
              ranking_class: 6,
              ranking_tier: 1,
              mythic_percentile: 0,
              mythic_placement: 0
            )
        )

      vm = LiveMatchCard.view_model(tick)

      assert vm.opponent_rank == "Mythic"
    end

    test "all ranking classes render with their tier" do
      classes = [
        {1, "Bronze"},
        {2, "Silver"},
        {3, "Gold"},
        {4, "Platinum"},
        {5, "Diamond"}
      ]

      for {class, label} <- classes do
        tick =
          match_info(opponent: player_info(ranking_class: class, ranking_tier: 4))

        vm = LiveMatchCard.view_model(tick)
        assert vm.opponent_rank == "#{label} 4"
      end
    end

    test "commander grpIds are surfaced for both players" do
      tick =
        match_info(
          local: player_info(commander_grp_ids: [12345]),
          opponent: player_info(commander_grp_ids: [67890, 11111])
        )

      vm = LiveMatchCard.view_model(tick)

      assert vm.local_commander_arena_ids == [12345]
      assert vm.opponent_commander_arena_ids == [67890, 11111]
    end

    test "current_game_number = 0 yields nil game_number" do
      tick = match_info(current_game_number: 0)
      vm = LiveMatchCard.view_model(tick)
      assert vm.game_number == nil
    end
  end

  defp player_info(overrides) do
    %{
      screen_name: nil,
      seat_id: 0,
      team_id: 0,
      ranking_class: 0,
      ranking_tier: 0,
      mythic_percentile: 0,
      mythic_placement: 0,
      commander_grp_ids: []
    }
    |> Map.merge(Map.new(overrides))
  end

  defp match_info(overrides) do
    %{
      local: player_info([]),
      opponent: player_info([]),
      match_id: "test-match",
      format: 0,
      variant: 0,
      session_type: 0,
      current_game_number: 1,
      match_state: 1,
      local_player_seat_id: 1,
      is_practice_game: false,
      is_private_game: false,
      reader_version: "rust:test"
    }
    |> Map.merge(Map.new(overrides))
  end
end
