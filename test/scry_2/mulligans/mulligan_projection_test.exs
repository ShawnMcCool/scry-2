defmodule Scry2.Mulligans.MulliganProjectionTest do
  use Scry2.DataCase

  import Scry2.TestFactory
  import Scry2.ProjectorCase

  alias Scry2.Events
  alias Scry2.Mulligans
  alias Scry2.Mulligans.MulliganProjection

  describe "rebuild!/0" do
    test "mulligan_offered creates a hand row with stats" do
      player = create_player()
      match_id = "test-mull-#{System.unique_integer([:positive])}"

      event =
        build_mulligan_offered(%{
          player_id: player.id,
          mtga_match_id: match_id,
          seat_id: 1,
          hand_size: 7,
          land_count: 3,
          nonland_count: 4,
          total_cmc: 12.0
        })

      project_events(MulliganProjection, event)

      hands = Mulligans.list_hands()
      hand = Enum.find(hands, &(&1.mtga_match_id == match_id))
      assert hand
      assert hand.hand_size == 7
      assert hand.land_count == 3
      assert hand.nonland_count == 4
      assert hand.total_cmc == 12.0
    end

    test "match_created stamps event_name on existing hands" do
      player = create_player()
      match_id = "test-mull-stamp-#{System.unique_integer([:positive])}"

      events = [
        build_mulligan_offered(%{
          player_id: player.id,
          mtga_match_id: match_id,
          seat_id: 1,
          hand_size: 7
        }),
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "PremierDraft_LCI"
        })
      ]

      project_events(MulliganProjection, events)

      hands = Mulligans.list_hands()
      hand = Enum.find(hands, &(&1.mtga_match_id == match_id))
      assert hand.event_name == "PremierDraft_LCI"
    end

    test "multiple mulligans for same match are all recorded" do
      player = create_player()
      match_id = "test-mull-multi-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now(:second)

      events = [
        build_mulligan_offered(%{
          player_id: player.id,
          mtga_match_id: match_id,
          seat_id: 1,
          hand_size: 7,
          occurred_at: now
        }),
        build_mulligan_offered(%{
          player_id: player.id,
          mtga_match_id: match_id,
          seat_id: 1,
          hand_size: 6,
          occurred_at: DateTime.add(now, 5, :second)
        })
      ]

      project_events(MulliganProjection, events)

      hands = Mulligans.list_hands() |> Enum.filter(&(&1.mtga_match_id == match_id))
      assert length(hands) == 2
      sizes = Enum.map(hands, & &1.hand_size) |> Enum.sort()
      assert sizes == [6, 7]
    end

    test "watermark advances to last processed event" do
      player = create_player()

      event = build_mulligan_offered(%{player_id: player.id})
      records = project_events(MulliganProjection, event)

      assert Events.get_watermark("Mulligans.MulliganProjection") == List.last(records).id
    end
  end
end
