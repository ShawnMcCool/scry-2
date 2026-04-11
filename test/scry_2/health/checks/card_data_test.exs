defmodule Scry2.Health.Checks.CardDataTest do
  use ExUnit.Case, async: true

  alias Scry2.Health.Check
  alias Scry2.Health.Checks.CardData

  describe "lands17_present/1" do
    test "error with enqueue fix when count is 0" do
      check = CardData.lands17_present(0)

      assert %Check{
               id: :lands17_present,
               category: :card_data,
               status: :error,
               fix: :enqueue_lands17
             } = check
    end

    test "ok when cards are present" do
      check = CardData.lands17_present(24_567)
      assert %Check{status: :ok} = check
      assert check.summary =~ "24567"
    end
  end

  describe "lands17_fresh/2" do
    test "ok within 7 days" do
      now = ~U[2026-04-11 12:00:00Z]
      updated_at = ~U[2026-04-08 12:00:00Z]
      check = CardData.lands17_fresh(updated_at, now)
      assert %Check{status: :ok} = check
      assert check.summary =~ "3 day"
    end

    test "warning when older than 7 days" do
      now = ~U[2026-04-11 12:00:00Z]
      updated_at = ~U[2026-04-01 12:00:00Z]
      check = CardData.lands17_fresh(updated_at, now)

      assert %Check{
               status: :warning,
               fix: :enqueue_lands17
             } = check
    end

    test "warning when updated_at is nil" do
      check = CardData.lands17_fresh(nil)
      assert %Check{status: :warning, fix: :enqueue_lands17} = check
    end
  end

  describe "scryfall_present/1" do
    test "error when count is 0" do
      check = CardData.scryfall_present(0)
      assert %Check{status: :error, fix: :enqueue_scryfall} = check
    end

    test "ok when present" do
      check = CardData.scryfall_present(113_456)
      assert %Check{status: :ok} = check
    end
  end

  describe "scryfall_fresh/2" do
    test "ok within 7 days" do
      now = ~U[2026-04-11 12:00:00Z]
      updated_at = ~U[2026-04-05 12:00:00Z]
      check = CardData.scryfall_fresh(updated_at, now)
      assert %Check{status: :ok} = check
    end

    test "warning when older than 7 days" do
      now = ~U[2026-04-11 12:00:00Z]
      updated_at = ~U[2026-03-20 12:00:00Z]
      check = CardData.scryfall_fresh(updated_at, now)
      assert %Check{status: :warning, fix: :enqueue_scryfall} = check
    end

    test "warning when nil" do
      check = CardData.scryfall_fresh(nil)
      assert %Check{status: :warning} = check
    end
  end
end
