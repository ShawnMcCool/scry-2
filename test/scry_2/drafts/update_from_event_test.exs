defmodule Scry2.Drafts.UpdateFromEventTest do
  use Scry2.DataCase

  alias Scry2.Drafts
  alias Scry2.Drafts.UpdateFromEvent
  alias Scry2.Events
  alias Scry2.Events.Draft.{DraftPickMade, DraftStarted}

  setup do
    name = Module.concat(__MODULE__, :"Projector#{System.unique_integer([:positive])}")
    pid = start_supervised!({UpdateFromEvent, name: name})
    %{projector: name, pid: pid}
  end

  defp sync(name), do: :sys.get_state(name) && :ok

  describe "projects %DraftStarted{} → drafts_drafts" do
    test "creates a new draft row", %{projector: name} do
      event = %DraftStarted{
        mtga_draft_id: "QuickDraft_TST_20260406",
        event_name: "QuickDraft_TST_20260406",
        set_code: "TST",
        occurred_at: ~U[2026-04-06 12:00:00Z]
      }

      Events.append!(event, nil)
      sync(name)

      draft = Drafts.get_by_mtga_id("QuickDraft_TST_20260406")
      assert draft != nil
      assert draft.set_code == "TST"
      assert draft.started_at == ~U[2026-04-06 12:00:00Z]
    end
  end

  describe "projects %DraftPickMade{} → drafts_picks" do
    test "creates a pick row linked to the draft", %{projector: name} do
      started = %DraftStarted{
        mtga_draft_id: "QuickDraft_TST_20260406",
        event_name: "QuickDraft_TST_20260406",
        set_code: "TST",
        occurred_at: ~U[2026-04-06 12:00:00Z]
      }

      Events.append!(started, nil)
      sync(name)

      pick = %DraftPickMade{
        mtga_draft_id: "QuickDraft_TST_20260406",
        pack_number: 1,
        pick_number: 1,
        picked_arena_id: 93959,
        pack_arena_ids: [],
        occurred_at: ~U[2026-04-06 12:01:00Z]
      }

      Events.append!(pick, nil)
      sync(name)

      draft =
        Drafts.get_draft_with_picks(Drafts.get_by_mtga_id("QuickDraft_TST_20260406").id)

      assert length(draft.picks) == 1

      [saved_pick] = draft.picks
      assert saved_pick.pack_number == 1
      assert saved_pick.pick_number == 1
      assert saved_pick.picked_arena_id == 93959
    end
  end
end
