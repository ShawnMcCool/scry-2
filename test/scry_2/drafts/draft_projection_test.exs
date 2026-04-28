defmodule Scry2.Drafts.DraftProjectionTest do
  use Scry2.DataCase

  import ExUnit.CaptureLog
  import Scry2.TestFactory
  import Scry2.ProjectorCase

  alias Scry2.Drafts
  alias Scry2.Drafts.DraftProjection
  alias Scry2.Events

  describe "rebuild!/0" do
    test "draft_started projects a draft row" do
      player = create_player()
      draft_id = "test-draft-#{System.unique_integer([:positive])}"

      event =
        build_draft_started(%{
          player_id: player.id,
          mtga_draft_id: draft_id,
          event_name: "QuickDraft_LCI",
          set_code: "LCI"
        })

      project_events(DraftProjection, event)

      draft = Drafts.get_by_mtga_id(draft_id, player.id)
      assert draft
      assert draft.event_name == "QuickDraft_LCI"
      assert draft.set_code == "LCI"
    end

    test "draft_pick_made creates a pick linked to the draft" do
      player = create_player()
      draft_id = "test-draft-pick-#{System.unique_integer([:positive])}"

      events = [
        build_draft_started(%{player_id: player.id, mtga_draft_id: draft_id}),
        build_draft_pick_made(%{
          player_id: player.id,
          mtga_draft_id: draft_id,
          pack_number: 1,
          pick_number: 3,
          picked_arena_id: 91_999
        })
      ]

      project_events(DraftProjection, events)

      draft = Drafts.get_by_mtga_id(draft_id, player.id)
      picks = Scry2.Repo.all(Scry2.Drafts.Pick) |> Enum.filter(&(&1.draft_id == draft.id))
      assert length(picks) == 1
      pick = hd(picks)
      assert pick.pack_number == 1
      assert pick.pick_number == 3
      assert pick.picked_arena_id == 91_999
    end

    test "draft_pick_made stores auto_pick and time_remaining on the pick" do
      player = create_player()
      draft_id = "test-draft-pick-meta-#{System.unique_integer([:positive])}"

      events = [
        build_draft_started(%{player_id: player.id, mtga_draft_id: draft_id}),
        build_draft_pick_made(%{
          player_id: player.id,
          mtga_draft_id: draft_id,
          pack_number: 1,
          pick_number: 1,
          picked_arena_id: 91_999,
          auto_pick: true,
          time_remaining: 4.5
        })
      ]

      project_events(DraftProjection, events)

      draft = Drafts.get_by_mtga_id(draft_id, player.id)
      pick = Drafts.get_draft_with_picks(draft.id).picks |> hd()
      assert pick.auto_pick == true
      assert pick.time_remaining == 4.5
    end

    test "draft_pick_made for unknown draft logs warning" do
      player = create_player()
      event = build_draft_pick_made(%{player_id: player.id, mtga_draft_id: "nonexistent-draft"})

      log = capture_log(fn -> project_events(DraftProjection, event) end)
      assert log =~ "unknown draft"
    end

    test "idempotent replay produces same state" do
      player = create_player()
      draft_id = "test-draft-idem-#{System.unique_integer([:positive])}"

      event = build_draft_started(%{player_id: player.id, mtga_draft_id: draft_id})
      project_events(DraftProjection, event)

      # Rebuild again
      DraftProjection.rebuild!()

      drafts =
        Scry2.Repo.all(Scry2.Drafts.Draft) |> Enum.filter(&(&1.mtga_draft_id == draft_id))

      assert length(drafts) == 1
    end

    test "watermark advances to last processed event" do
      player = create_player()

      event = build_draft_started(%{player_id: player.id})
      records = project_events(DraftProjection, event)

      assert Events.get_watermark("Drafts.DraftProjection") == List.last(records).id
    end
  end

  describe "DraftStarted — format derivation" do
    test "derives quick_draft from QuickDraft_ event name" do
      player = create_player()
      draft_id = "QuickDraft_FDN_#{System.unique_integer([:positive])}"

      event =
        build_draft_started(%{
          player_id: player.id,
          event_name: "QuickDraft_FDN_20260401",
          mtga_draft_id: draft_id,
          set_code: "FDN"
        })

      project_events(DraftProjection, event)

      draft = Drafts.get_by_mtga_id(draft_id, player.id)
      assert draft.format == "quick_draft"
    end

    test "derives premier_draft from PremierDraft_ event name" do
      player = create_player()
      draft_id = "PremierDraft_FDN_#{System.unique_integer([:positive])}"

      event =
        build_draft_started(%{
          player_id: player.id,
          event_name: "PremierDraft_FDN_20260401",
          mtga_draft_id: draft_id,
          set_code: "FDN"
        })

      project_events(DraftProjection, event)

      draft = Drafts.get_by_mtga_id(draft_id, player.id)
      assert draft.format == "premier_draft"
    end

    test "derives traditional_draft from TradDraft_ event name" do
      player = create_player()
      draft_id = "TradDraft_FDN_#{System.unique_integer([:positive])}"

      event =
        build_draft_started(%{
          player_id: player.id,
          event_name: "TradDraft_FDN_20260401",
          mtga_draft_id: draft_id,
          set_code: "FDN"
        })

      project_events(DraftProjection, event)

      draft = Drafts.get_by_mtga_id(draft_id, player.id)
      assert draft.format == "traditional_draft"
    end

    test "derives pick_two_draft from PickTwoDraft_ event name (CourseId-keyed)" do
      player = create_player()
      draft_id = Ecto.UUID.generate()

      event =
        build_draft_started(%{
          player_id: player.id,
          event_name: "PickTwoDraft_SOS_20260421",
          mtga_draft_id: draft_id,
          set_code: "SOS"
        })

      project_events(DraftProjection, event)

      draft = Drafts.get_by_mtga_id(draft_id, player.id)
      assert draft.format == "pick_two_draft"
      assert draft.set_code == "SOS"
    end
  end

  describe "DraftCompleted" do
    test "sets card_pool_arena_ids and completed_at on the draft" do
      player = create_player()
      draft_id = "QuickDraft_FDN_#{System.unique_integer([:positive])}"
      pool = [11111, 22222, 33333]

      events = [
        build_draft_started(%{
          player_id: player.id,
          mtga_draft_id: draft_id,
          event_name: draft_id
        }),
        build_draft_completed(%{
          player_id: player.id,
          mtga_draft_id: draft_id,
          event_name: draft_id,
          card_pool_arena_ids: pool,
          is_bot_draft: true,
          occurred_at: DateTime.utc_now(:second)
        })
      ]

      project_events(DraftProjection, events)

      updated = Drafts.get_by_mtga_id(draft_id, player.id)
      assert updated.card_pool_arena_ids == %{"ids" => pool}
      assert updated.completed_at != nil
    end

    test "is a no-op when draft row does not exist" do
      player = create_player()

      event =
        build_draft_completed(%{
          player_id: player.id,
          mtga_draft_id: "UnknownDraft_FDN_#{System.unique_integer([:positive])}",
          card_pool_arena_ids: [1, 2, 3]
        })

      log = capture_log(fn -> project_events(DraftProjection, event) end)
      assert log =~ "unknown draft"
    end
  end

  describe "HumanDraftPackOffered" do
    test "creates draft row if none exists yet" do
      player = create_player()
      draft_id = "PremierDraft_FDN_#{System.unique_integer([:positive])}"

      event =
        build_human_draft_pack_offered(%{
          player_id: player.id,
          mtga_draft_id: draft_id,
          pack_number: 1,
          pick_number: 2,
          pack_arena_ids: [11111, 22222, 33333]
        })

      project_events(DraftProjection, event)

      draft = Drafts.get_by_mtga_id(draft_id, player.id)
      assert draft != nil
      assert draft.format == "premier_draft"
      assert draft.set_code == "FDN"
    end

    test "stores pack_arena_ids on the pick row" do
      player = create_player()
      draft_id = "PremierDraft_FDN_#{System.unique_integer([:positive])}"
      pack = [11111, 22222, 33333]

      event =
        build_human_draft_pack_offered(%{
          player_id: player.id,
          mtga_draft_id: draft_id,
          pack_number: 1,
          pick_number: 2,
          pack_arena_ids: pack
        })

      project_events(DraftProjection, event)

      draft = Drafts.get_by_mtga_id(draft_id, player.id)
      updated = Drafts.get_draft_with_picks(draft.id)
      pick = Enum.find(updated.picks, &(&1.pack_number == 1 and &1.pick_number == 2))
      assert pick.pack_arena_ids == %{"cards" => pack}
      assert pick.picked_arena_id == nil
    end
  end

  describe "HumanDraftPickMade" do
    test "stamps picked_arena_id on an existing pick row (preserving pack contents)" do
      player = create_player()
      draft_id = "PremierDraft_FDN_#{System.unique_integer([:positive])}"

      events = [
        build_human_draft_pack_offered(%{
          player_id: player.id,
          mtga_draft_id: draft_id,
          pack_number: 1,
          pick_number: 2,
          pack_arena_ids: [11111, 22222, 33333]
        }),
        build_human_draft_pick_made(%{
          player_id: player.id,
          mtga_draft_id: draft_id,
          pack_number: 1,
          pick_number: 2,
          picked_arena_ids: [11111]
        })
      ]

      project_events(DraftProjection, events)

      draft = Drafts.get_by_mtga_id(draft_id, player.id)
      updated = Drafts.get_draft_with_picks(draft.id)
      pick = Enum.find(updated.picks, &(&1.pack_number == 1 and &1.pick_number == 2))
      assert pick.picked_arena_id == 11111
      assert pick.pack_arena_ids == %{"cards" => [11111, 22222, 33333]}
    end
  end

  describe "wins/losses from matches:updates" do
    test "updates draft wins and losses when a match for its event_name is broadcast" do
      player = create_player()
      event_name = "QuickDraft_FDN_#{System.unique_integer([:positive])}"

      draft_started_event =
        build_draft_started(%{
          player_id: player.id,
          mtga_draft_id: event_name,
          event_name: event_name,
          set_code: "FDN"
        })

      project_events(DraftProjection, draft_started_event)

      match1 =
        create_match(%{player_id: player.id, event_name: event_name, won: true})

      match2 =
        create_match(%{player_id: player.id, event_name: event_name, won: true})

      _match3 =
        create_match(%{player_id: player.id, event_name: event_name, won: false})

      # Simulate receiving a match_updated broadcast
      DraftProjection.handle_extra_info_for_test({:match_updated, match1.id}, %{})

      updated = Drafts.get_by_mtga_id(event_name, player.id)
      assert updated.wins == 2
      assert updated.losses == 1

      _ = match2
    end
  end
end
