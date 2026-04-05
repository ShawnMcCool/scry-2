defmodule Scry2.MtgaLogsTest do
  use Scry2.DataCase, async: true

  alias Scry2.MtgaLogs
  alias Scry2.TestFactory
  alias Scry2.Topics

  describe "insert_event!/1" do
    test "persists the raw event and broadcasts to mtga_logs:events (ADR-015)" do
      Topics.subscribe(Topics.mtga_logs_events())

      record =
        MtgaLogs.insert_event!(%{
          event_type: "MatchStart",
          file_offset: 0,
          source_file: "/tmp/fake.log",
          raw_json: ~s({"foo":"bar"})
        })

      assert record.event_type == "MatchStart"
      assert record.raw_json == ~s({"foo":"bar"})
      assert record.processed == false

      assert_receive {:event, id, "MatchStart"}
      assert id == record.id
    end
  end

  describe "list_unprocessed/1 and mark_processed!/1" do
    test "only returns unprocessed rows and marks them as processed" do
      a = TestFactory.create_event_record(%{event_type: "MatchStart"})
      b = TestFactory.create_event_record(%{event_type: "MatchEnd"})

      unprocessed = MtgaLogs.list_unprocessed()
      assert Enum.any?(unprocessed, &(&1.id == a.id))
      assert Enum.any?(unprocessed, &(&1.id == b.id))

      :ok = MtgaLogs.mark_processed!(a.id)

      remaining = MtgaLogs.list_unprocessed()
      refute Enum.any?(remaining, &(&1.id == a.id))
      assert Enum.any?(remaining, &(&1.id == b.id))
    end

    test "filters by event_type when requested" do
      TestFactory.create_event_record(%{event_type: "MatchStart"})
      TestFactory.create_event_record(%{event_type: "MatchEnd"})

      only_starts = MtgaLogs.list_unprocessed(types: ["MatchStart"])
      assert Enum.all?(only_starts, &(&1.event_type == "MatchStart"))
    end
  end

  describe "cursor persistence (ADR-012 durable process design)" do
    test "upserts and resumes a cursor by file_path" do
      path = "/tmp/scry2-cursor-test-#{System.unique_integer([:positive])}.log"

      first = MtgaLogs.put_cursor!(%{file_path: path, byte_offset: 100})
      second = MtgaLogs.put_cursor!(%{file_path: path, byte_offset: 250})

      assert first.id == second.id
      assert second.byte_offset == 250

      assert MtgaLogs.get_cursor(path).byte_offset == 250
    end
  end
end
