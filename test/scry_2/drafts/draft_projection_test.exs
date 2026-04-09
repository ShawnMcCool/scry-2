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
end
