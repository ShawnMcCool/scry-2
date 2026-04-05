defmodule Scry2.Console.EntryTest do
  use ExUnit.Case, async: true

  alias Scry2.Console.Entry

  describe "new/1" do
    test "builds an entry from a map with required keys" do
      now = DateTime.utc_now()

      entry =
        Entry.new(%{
          id: 1,
          timestamp: now,
          level: :info,
          component: :ingester,
          message: "processed 3 events"
        })

      assert %Entry{
               id: 1,
               timestamp: ^now,
               level: :info,
               component: :ingester,
               message: "processed 3 events",
               module: nil,
               metadata: %{}
             } = entry
    end

    test "accepts a keyword list" do
      entry =
        Entry.new(
          id: 2,
          timestamp: ~U[2026-04-05 12:00:00Z],
          level: :warning,
          component: :watcher,
          message: "backlog 42"
        )

      assert entry.level == :warning
      assert entry.component == :watcher
      assert entry.message == "backlog 42"
    end

    test "accepts optional :module and :metadata" do
      entry =
        Entry.new(%{
          id: 3,
          timestamp: DateTime.utc_now(),
          level: :error,
          component: :importer,
          message: "boom",
          module: Scry2.Cards.Lands17Importer,
          metadata: %{foo: "bar"}
        })

      assert entry.module == Scry2.Cards.Lands17Importer
      assert entry.metadata == %{foo: "bar"}
    end

    test "raises KeyError when a required key is missing" do
      assert_raise KeyError, fn ->
        Entry.new(%{id: 1, timestamp: DateTime.utc_now(), level: :info, component: :http})
      end
    end
  end
end
