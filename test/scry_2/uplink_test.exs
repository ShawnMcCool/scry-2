defmodule Scry2.UplinkTest do
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.TestFactory
  alias Scry2.Uplink

  defp append_match_created(match_id) do
    raw = TestFactory.create_event_record(%{event_type: "MatchGameRoomStateChangedEvent"})
    Events.append!(TestFactory.build_match_created(%{mtga_match_id: match_id}), raw)
  end

  describe "unsent_batch/1 and mark_sent!/1" do
    test "returns all appended events as wire maps in id order when the cursor is fresh" do
      append_match_created("m-1")
      append_match_created("m-2")

      {wire, new_cursor} = Uplink.unsent_batch()

      assert length(wire) == 2
      assert Enum.map(wire, & &1["payload"]["mtga_match_id"]) == ["m-1", "m-2"]
      assert new_cursor > 0
      assert Enum.all?(wire, &Map.has_key?(&1, "upload_key"))
    end

    test "advancing the cursor with mark_sent!/1 drains the batch" do
      append_match_created("m-1")
      {_wire, cursor} = Uplink.unsent_batch()

      Uplink.mark_sent!(cursor)

      assert {[], ^cursor} = Uplink.unsent_batch()
    end

    test "events appended after mark_sent!/1 are picked up on the next batch" do
      append_match_created("m-1")
      {_wire, cursor} = Uplink.unsent_batch()
      Uplink.mark_sent!(cursor)

      append_match_created("m-2")
      {wire, _cursor} = Uplink.unsent_batch()

      assert Enum.map(wire, & &1["payload"]["mtga_match_id"]) == ["m-2"]
    end

    test "respects the limit and stops at the last returned id" do
      append_match_created("m-1")
      append_match_created("m-2")
      append_match_created("m-3")

      {wire, cursor} = Uplink.unsent_batch(2)

      assert length(wire) == 2
      Uplink.mark_sent!(cursor)

      {rest, _} = Uplink.unsent_batch(2)
      assert Enum.map(rest, & &1["payload"]["mtga_match_id"]) == ["m-3"]
    end

    test "cursor/0 reflects the last mark_sent!/1" do
      append_match_created("m-1")
      {_wire, cursor} = Uplink.unsent_batch()
      Uplink.mark_sent!(cursor)

      assert Uplink.cursor() == cursor
    end
  end
end
