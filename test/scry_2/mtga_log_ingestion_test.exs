defmodule Scry2.MtgaLogIngestionTest do
  use Scry2.DataCase, async: true

  alias Scry2.MtgaLogIngestion
  alias Scry2.TestFactory
  alias Scry2.Topics

  describe "insert_event!/1" do
    test "persists the raw event and broadcasts to mtga_logs:events (ADR-015)" do
      Topics.subscribe(Topics.mtga_logs_events())

      record =
        MtgaLogIngestion.insert_event!(%{
          event_type: "MatchStart",
          file_offset: 0,
          source_file: "/tmp/fake.log",
          raw_json: ~s({"foo":"bar"})
        })

      assert record.event_type == "MatchStart"
      assert record.raw_json == ~s({"foo":"bar"})
      assert record.processed == false

      assert_receive {:event, %{id: id, event_type: "MatchStart"}}
      assert id == record.id
    end

    test "duplicate (source_file, file_offset) is silently skipped (ADR-016)" do
      Topics.subscribe(Topics.mtga_logs_events())

      attrs = %{
        event_type: "MatchStart",
        file_offset: 42,
        source_file: "/tmp/dedup-test.log",
        raw_json: ~s({"foo":"bar"})
      }

      first = MtgaLogIngestion.insert_event!(attrs)
      assert first != nil
      assert first.id != nil
      assert_receive {:event, %{id: _}}

      second = MtgaLogIngestion.insert_event!(attrs)
      assert second == nil
      refute_receive {:event, _}

      all = MtgaLogIngestion.list_unprocessed()

      dupes =
        Enum.filter(all, &(&1.file_offset == 42 and &1.source_file == "/tmp/dedup-test.log"))

      assert length(dupes) == 1
    end
  end

  describe "list_unprocessed/1 and mark_processed!/1" do
    test "only returns unprocessed rows and marks them as processed" do
      a = TestFactory.create_event_record(%{event_type: "MatchStart"})
      b = TestFactory.create_event_record(%{event_type: "MatchEnd"})

      unprocessed = MtgaLogIngestion.list_unprocessed()
      assert Enum.any?(unprocessed, &(&1.id == a.id))
      assert Enum.any?(unprocessed, &(&1.id == b.id))

      :ok = MtgaLogIngestion.mark_processed!(a.id)

      remaining = MtgaLogIngestion.list_unprocessed()
      refute Enum.any?(remaining, &(&1.id == a.id))
      assert Enum.any?(remaining, &(&1.id == b.id))
    end

    test "filters by event_type when requested" do
      TestFactory.create_event_record(%{event_type: "MatchStart"})
      TestFactory.create_event_record(%{event_type: "MatchEnd"})

      only_starts = MtgaLogIngestion.list_unprocessed(types: ["MatchStart"])
      assert Enum.all?(only_starts, &(&1.event_type == "MatchStart"))
    end
  end

  describe "cursor persistence (ADR-012 durable process design)" do
    test "upserts and resumes a cursor by file_path" do
      path = "/tmp/scry2-cursor-test-#{System.unique_integer([:positive])}.log"

      first = MtgaLogIngestion.put_cursor!(%{file_path: path, byte_offset: 100})
      second = MtgaLogIngestion.put_cursor!(%{file_path: path, byte_offset: 250})

      assert first.id == second.id
      assert second.byte_offset == 250

      assert MtgaLogIngestion.get_cursor(path).byte_offset == 250
    end
  end

  describe "get_event!/1" do
    test "returns the event record by id" do
      record = TestFactory.create_event_record(%{event_type: "MatchGameRoomStateChangedEvent"})

      loaded = MtgaLogIngestion.get_event!(record.id)
      assert loaded.id == record.id
      assert loaded.event_type == "MatchGameRoomStateChangedEvent"
      assert loaded.raw_json == record.raw_json
    end

    test "raises Ecto.NoResultsError when id does not exist" do
      assert_raise Ecto.NoResultsError, fn -> MtgaLogIngestion.get_event!(-1) end
    end
  end

  describe "mark_error!/2" do
    @tag capture_log: true
    test "records processing_error without marking the event processed" do
      record = TestFactory.create_event_record()

      assert :ok = MtgaLogIngestion.mark_error!(record.id, %ArgumentError{message: "bad payload"})

      reloaded = MtgaLogIngestion.get_event!(record.id)
      assert reloaded.processed == false
      assert reloaded.processing_error == "bad payload"
    end
  end

  describe "list_ordered_after/2" do
    test "returns events with id > cursor, ordered ascending" do
      a = TestFactory.create_event_record(%{event_type: "TypeA"})
      b = TestFactory.create_event_record(%{event_type: "TypeB"})
      c = TestFactory.create_event_record(%{event_type: "TypeC"})

      all = MtgaLogIngestion.list_ordered_after(0)
      ids = Enum.map(all, & &1.id)
      assert a.id in ids
      assert b.id in ids
      assert c.id in ids

      after_a = MtgaLogIngestion.list_ordered_after(a.id)
      after_ids = Enum.map(after_a, & &1.id)
      refute a.id in after_ids
      assert b.id in after_ids
      assert c.id in after_ids
    end

    test "respects the limit option" do
      Enum.each(1..5, fn i ->
        TestFactory.create_event_record(%{event_type: "Type#{i}"})
      end)

      result = MtgaLogIngestion.list_ordered_after(0, limit: 2)
      assert length(result) == 2
    end

    test "returns empty list when cursor is past all records" do
      record = TestFactory.create_event_record()
      assert MtgaLogIngestion.list_ordered_after(record.id) == []
    end
  end

  describe "bulk_mark_processed!/1 (id list)" do
    test "marks only the given ids as processed, leaving others untouched" do
      a = TestFactory.create_event_record(%{event_type: "TypeA"})
      b = TestFactory.create_event_record(%{event_type: "TypeB"})
      c = TestFactory.create_event_record(%{event_type: "TypeC"})

      MtgaLogIngestion.bulk_mark_processed!([a.id, b.id])

      assert MtgaLogIngestion.get_event!(a.id).processed == true
      assert MtgaLogIngestion.get_event!(b.id).processed == true
      assert MtgaLogIngestion.get_event!(c.id).processed == false
    end

    test "is a no-op for an empty list" do
      assert :ok = MtgaLogIngestion.bulk_mark_processed!([])
    end
  end

  describe "count_by_type/0" do
    test "returns a map of event_type => count" do
      TestFactory.create_event_record(%{event_type: "MatchGameRoomStateChangedEvent"})
      TestFactory.create_event_record(%{event_type: "MatchGameRoomStateChangedEvent"})
      TestFactory.create_event_record(%{event_type: "EventJoin"})

      counts = MtgaLogIngestion.count_by_type()
      assert counts["MatchGameRoomStateChangedEvent"] == 2
      assert counts["EventJoin"] == 1
    end
  end
end
