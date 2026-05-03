defmodule Scry2.Collection.SnapshotTest do
  use Scry2.DataCase, async: false

  alias Scry2.Collection.Snapshot
  alias Scry2.TestFactory

  describe "changeset/2" do
    test "derives cards_json, card_count, and total_copies from :entries" do
      entries = [{30_001, 2}, {30_002, 3}]

      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          entries: entries,
          snapshot_ts: DateTime.utc_now(),
          reader_version: "v0.0.0-test",
          reader_confidence: "fallback_scan"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :card_count) == 2
      assert Ecto.Changeset.get_change(changeset, :total_copies) == 5

      cards_json = Ecto.Changeset.get_change(changeset, :cards_json)
      decoded = Snapshot.decode_entries(cards_json)
      assert decoded == entries
    end

    test "rejects unknown reader_confidence values" do
      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          entries: [],
          snapshot_ts: DateTime.utc_now(),
          reader_version: "v0.0.0",
          reader_confidence: "clairvoyance"
        })

      refute changeset.valid?
      assert %{reader_confidence: [_]} = errors_on(changeset)
    end

    test "requires the baseline fields" do
      changeset = Snapshot.changeset(%Snapshot{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:snapshot_ts]
      assert errors[:reader_version]
      assert errors[:reader_confidence]
    end

    test "rejects negative card_count / total_copies" do
      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          snapshot_ts: DateTime.utc_now(),
          reader_version: "v0.0.0",
          reader_confidence: "walker",
          cards_json: "[]",
          card_count: -1,
          total_copies: -5
        })

      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:card_count]
      assert errors[:total_copies]
    end

    test "accepts walker reader_confidence plus the walker-only fields" do
      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          snapshot_ts: DateTime.utc_now(),
          reader_version: "v0.0.0",
          reader_confidence: "walker",
          entries: [{30_001, 1}],
          wildcards_common: 50,
          wildcards_uncommon: 40,
          wildcards_rare: 30,
          wildcards_mythic: 20,
          gold: 99_999,
          gems: 1234,
          vault_progress: 55
        })

      assert changeset.valid?
    end
  end

  describe "entries round-trip via encode/decode" do
    test "re-materialises entries unchanged" do
      entries = [{30_001, 1}, {91_234, 4}, {200_000, 2}]
      decoded = entries |> Snapshot.encode_entries() |> Snapshot.decode_entries()
      assert decoded == entries
    end
  end

  describe "boosters round-trip via encode/decode" do
    test "re-materialises booster rows unchanged from atom-keyed walker output" do
      boosters = [
        %{collation_id: 100_060, count: 99},
        %{collation_id: 100_345, count: 1}
      ]

      decoded = boosters |> Snapshot.encode_boosters() |> Snapshot.decode_boosters()
      assert decoded == [{100_060, 99}, {100_345, 1}]
    end

    test "re-materialises booster rows unchanged from string-keyed input" do
      boosters = [%{"collation_id" => 100_060, "count" => 99}]
      decoded = boosters |> Snapshot.encode_boosters() |> Snapshot.decode_boosters()
      assert decoded == [{100_060, 99}]
    end

    test "decode_boosters handles nil and the literal 'null' JSON" do
      assert Snapshot.decode_boosters(nil) == []
      assert Snapshot.decode_boosters("null") == []
    end

    test "encode_boosters of an empty list is a valid empty JSON array" do
      assert Snapshot.encode_boosters([]) == "[]"
      assert Snapshot.decode_boosters("[]") == []
    end
  end

  describe "changeset with match-tag columns" do
    test "accepts mtga_match_id and match_phase" do
      attrs = base_attrs(%{mtga_match_id: "abc-123", match_phase: "pre"})
      cs = Snapshot.changeset(%Snapshot{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :mtga_match_id) == "abc-123"
      assert Ecto.Changeset.get_change(cs, :match_phase) == "pre"
    end

    test "leaves both nil when neither given (background snapshot)" do
      cs = Snapshot.changeset(%Snapshot{}, base_attrs(%{}))
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :mtga_match_id) == nil
      assert Ecto.Changeset.get_change(cs, :match_phase) == nil
    end

    test "rejects match_phase outside the allowed set" do
      attrs = base_attrs(%{mtga_match_id: "x", match_phase: "garbage"})
      cs = Snapshot.changeset(%Snapshot{}, attrs)
      refute cs.valid?
      assert {:match_phase, _} = List.keyfind(cs.errors, :match_phase, 0)
    end
  end

  describe "create_collection_snapshot factory" do
    test "persists via changeset and round-trips cards_json" do
      snapshot = TestFactory.create_collection_snapshot(entries: [{30_001, 3}, {91_234, 1}])

      reloaded = Repo.get!(Snapshot, snapshot.id)

      assert reloaded.card_count == 2
      assert reloaded.total_copies == 4
      assert Snapshot.decode_entries(reloaded.cards_json) == [{30_001, 3}, {91_234, 1}]
    end
  end

  describe "mastery field round-trip" do
    test "persists and reloads all mastery fields" do
      attrs = %{
        snapshot_ts: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        reader_version: "test",
        reader_confidence: "walker",
        card_count: 0,
        total_copies: 0,
        cards_json: "[]",
        mastery_tier: 17,
        mastery_xp_in_tier: 500,
        mastery_orbs: 0,
        mastery_season_name: "BattlePass_SOS",
        mastery_season_ends_at: ~U[2026-09-15 00:00:00Z]
      }

      changeset = Snapshot.changeset(%Snapshot{}, attrs)
      assert changeset.valid?

      {:ok, saved} = Repo.insert(changeset)
      reloaded = Repo.get!(Snapshot, saved.id)

      assert reloaded.mastery_tier == 17
      assert reloaded.mastery_xp_in_tier == 500
      assert reloaded.mastery_orbs == 0
      assert reloaded.mastery_season_name == "BattlePass_SOS"
      assert reloaded.mastery_season_ends_at == ~U[2026-09-15 00:00:00Z]
    end

    test "snapshot is valid without any mastery fields (all nullable)" do
      attrs = %{
        snapshot_ts: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        reader_version: "test",
        reader_confidence: "walker",
        card_count: 0,
        total_copies: 0,
        cards_json: "[]"
      }

      changeset = Snapshot.changeset(%Snapshot{}, attrs)
      assert changeset.valid?
    end
  end

  defp base_attrs(extra) do
    Map.merge(
      %{
        snapshot_ts: DateTime.utc_now(),
        reader_version: "test",
        reader_confidence: "walker",
        entries: [{30_001, 1}]
      },
      extra
    )
  end
end
