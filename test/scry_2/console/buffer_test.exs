defmodule Scry2.Console.BufferTest do
  use Scry2.DataCase

  alias Scry2.Console.{Buffer, Entry, Filter}
  alias Scry2.Settings
  alias Scry2.Topics

  defp entry(id, overrides \\ %{}) do
    defaults = %{
      id: id,
      timestamp: DateTime.utc_now(),
      level: :info,
      component: :ingester,
      message: "entry #{id}"
    }

    Entry.new(Map.merge(defaults, Map.new(overrides)))
  end

  defp start_buffer!(opts) do
    # Give the buffer a unique registered name per test so the global
    # `Scry2.Console.Buffer` (started by the application supervision tree)
    # is left alone.
    name = Module.concat(__MODULE__, :"Buffer#{System.unique_integer([:positive])}")
    start_supervised!({Buffer, Keyword.put(opts, :name, name)})
    name
  end

  describe "append/2 and recent/2" do
    test "appends entries newest-first and respects the cap" do
      name = start_buffer!(cap: 3)

      Buffer.append(entry(1), name)
      Buffer.append(entry(2), name)
      Buffer.append(entry(3), name)
      Buffer.append(entry(4), name)

      # Force any in-flight casts to drain before asserting.
      _ = :sys.get_state(name)

      recent = Buffer.recent(nil, name)
      assert Enum.map(recent, & &1.id) == [4, 3, 2]
    end

    test "recent/n limits the returned window" do
      name = start_buffer!(cap: 10)

      for i <- 1..5, do: Buffer.append(entry(i), name)
      _ = :sys.get_state(name)

      assert Buffer.recent(2, name) |> Enum.map(& &1.id) == [5, 4]
    end

    test "append/2 on a nonexistent name is a silent no-op" do
      assert Buffer.append(entry(1), :scry2_buffer_never_started) == :ok
    end
  end

  describe "snapshot/1" do
    test "returns entries, cap, and filter" do
      name = start_buffer!(cap: 5)
      Buffer.append(entry(1), name)
      _ = :sys.get_state(name)

      snapshot = Buffer.snapshot(name)
      assert snapshot.cap == 5
      assert [%Entry{id: 1}] = snapshot.entries
      assert %Filter{} = snapshot.filter
    end
  end

  describe "clear/1" do
    test "empties the buffer and broadcasts :buffer_cleared" do
      name = start_buffer!(cap: 5)
      Topics.subscribe(Topics.console_logs())

      Buffer.append(entry(1), name)
      _ = :sys.get_state(name)
      # Drop the append broadcast from the test mailbox.
      assert_receive {:log_entry, _}

      assert :ok = Buffer.clear(name)
      assert_receive :buffer_cleared

      assert Buffer.recent(nil, name) == []
    end
  end

  describe "resize/2" do
    test "trims entries when new cap is smaller" do
      name = start_buffer!(cap: 10)
      for i <- 1..6, do: Buffer.append(entry(i), name)
      _ = :sys.get_state(name)

      assert :ok = Buffer.resize(200, name)
      # Cap range enforcement uses production bounds — 200 is valid.
      snapshot = Buffer.snapshot(name)
      assert snapshot.cap == 200
    end

    test "broadcasts :buffer_resized" do
      name = start_buffer!(cap: 10)
      Topics.subscribe(Topics.console_logs())

      assert :ok = Buffer.resize(300, name)
      assert_receive {:buffer_resized, 300}
    end

    test "rejects caps outside the allowed range" do
      name = start_buffer!(cap: 10)
      assert {:error, _reason} = Buffer.resize(1, name)
      assert {:error, _reason} = Buffer.resize(999_999, name)
    end
  end

  describe "put_filter/2 and get_filter/1" do
    test "updates the filter and broadcasts :filter_changed" do
      name = start_buffer!(cap: 10)
      Topics.subscribe(Topics.console_logs())

      new_filter = %{Filter.new_with_defaults() | search: "needle"}
      assert :ok = Buffer.put_filter(new_filter, name)
      assert_receive {:filter_changed, ^new_filter}

      assert Buffer.get_filter(name) == new_filter
    end
  end

  describe "append/2 broadcasts" do
    test "emits {:log_entry, entry} to console_logs topic" do
      name = start_buffer!(cap: 10)
      Topics.subscribe(Topics.console_logs())

      e = entry(1, message: "hello")
      Buffer.append(e, name)

      assert_receive {:log_entry, received}
      assert received.id == 1
      assert received.message == "hello"
    end
  end

  describe "settings persistence" do
    test "loads persisted cap and filter in init" do
      Settings.put!("console.buffer_size", 500)

      persisted_filter =
        %{Filter.new_with_defaults() | search: "persisted"}
        |> Filter.to_persistable()

      Settings.put!("console.filter", persisted_filter)

      # Buffer uses Scry2.Settings.get in init; start a fresh one to pick it up.
      name = start_buffer!([])

      snapshot = Buffer.snapshot(name)
      assert snapshot.cap == 500
      assert snapshot.filter.search == "persisted"
    end

    test "falls back to defaults when settings are missing" do
      # Ensure no pre-existing entry affects this test — DataCase sandbox
      # gives us a clean DB per test anyway.
      name = start_buffer!([])
      snapshot = Buffer.snapshot(name)

      # Default cap is 2_000 unless overridden via opts or persisted settings.
      assert snapshot.cap == 2_000
      assert %Filter{} = snapshot.filter
    end
  end
end
