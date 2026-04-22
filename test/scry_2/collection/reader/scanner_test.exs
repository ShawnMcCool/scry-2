defmodule Scry2.Collection.Reader.ScannerTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.Reader.Scanner

  # Builds a synthetic Dictionary<int,int> entries binary whose layout
  # matches the Mono runtime shape the scanner recognises:
  # {int32 hash_code; int32 next; int32 key; int32 value}, 16 bytes.
  defp entry(arena_id, count) do
    hash = Bitwise.band(arena_id, 0x7FFFFFFF)

    <<hash::little-signed-32, -1::little-signed-32, arena_id::little-signed-32,
      count::little-signed-32>>
  end

  defp empty_slot do
    <<-1::little-signed-32, -1::little-signed-32, 0::little-signed-32, 0::little-signed-32>>
  end

  defp junk_16 do
    # Bytes that fail both used_slot? and empty_slot?.
    <<0::little-signed-32, 99_999_999::little-signed-32, 0::little-signed-32,
      0::little-signed-32>>
  end

  defp run_of(n, start_arena_id \\ 30_000) do
    Enum.map_join(0..(n - 1), "", fn offset ->
      entry(start_arena_id + offset, rem(offset, 4) + 1)
    end)
  end

  describe "feed/3 + finalize/1" do
    test "extracts a run of used entries longer than min_run" do
      min_run = 10
      state = Scanner.initial_state(min_run: min_run)

      # 12 valid entries + 16 bytes of junk to close the run.
      bin = run_of(12) <> junk_16()
      {state, _tail} = Scanner.feed(bin, 0x1000, state)

      %{entries: entries, entries_start: entries_start} = Scanner.finalize(state)

      assert length(entries) == 12
      assert entries_start == 0x1000
      assert List.first(entries) == {30_000, 1}
      assert List.last(entries) == {30_011, 4}
    end

    test "ignores runs shorter than min_run" do
      state = Scanner.initial_state(min_run: 20)
      bin = run_of(10) <> junk_16()
      {state, _tail} = Scanner.feed(bin, 0x1000, state)

      %{entries: entries, entries_start: entries_start} = Scanner.finalize(state)
      assert entries == []
      assert entries_start == nil
    end

    test "keeps the longest run when multiple valid runs are present" do
      state = Scanner.initial_state(min_run: 3)
      # short run (5), then junk, then longer run (8)
      bin = run_of(5) <> junk_16() <> run_of(8, 60_000) <> junk_16()
      {state, _tail} = Scanner.feed(bin, 0x2000, state)

      %{entries: entries, entries_start: entries_start} = Scanner.finalize(state)
      assert length(entries) == 8
      assert entries_start == 0x2000 + 5 * 16 + 16
      assert List.first(entries) == {60_000, 1}
    end

    test "returns the trailing incomplete chunk so the caller can carry it" do
      state = Scanner.initial_state(min_run: 5)
      # 5 valid entries + 3 extra bytes that don't form a full entry
      bin = run_of(5) <> <<0xFF, 0xFF, 0xFF>>
      {_state, tail} = Scanner.feed(bin, 0x3000, state)

      assert tail == <<0xFF, 0xFF, 0xFF>>
    end

    test "counts empty-slot sentinels as part of a run without recording them" do
      state = Scanner.initial_state(min_run: 4)
      # 3 used + 2 empty slots + junk — the 5-wide run spans used + empty.
      bin = run_of(3) <> empty_slot() <> empty_slot() <> junk_16()
      {state, _tail} = Scanner.feed(bin, 0x4000, state)

      %{entries: entries} = Scanner.finalize(state)

      # Only used entries are recorded, but the run continues through
      # empty slots so it clears the min_run threshold.
      assert length(entries) == 3
      assert Enum.all?(entries, fn {arena_id, _count} -> arena_id >= 30_000 end)
    end

    test "splits cleanly across multiple feed calls (streaming)" do
      state = Scanner.initial_state(min_run: 10)
      full = run_of(12) <> junk_16()

      # Split mid-entry to exercise the carry path.
      split_at = 16 * 7 + 5
      <<first::binary-size(split_at), second::binary>> = full

      {state, tail} = Scanner.feed(first, 0x5000, state)
      carry = tail
      combined = <<carry::binary, second::binary>>
      {state, _tail} = Scanner.feed(combined, 0x5000 + split_at - byte_size(carry), state)

      %{entries: entries, entries_start: entries_start} = Scanner.finalize(state)

      assert length(entries) == 12
      assert entries_start == 0x5000
    end
  end

  describe "validation predicates" do
    test "rejects entries whose hash doesn't match key & 0x7FFFFFFF" do
      state = Scanner.initial_state(min_run: 2)

      # Forge an entry where hash_code is wrong.
      bad =
        <<0xDEAD::little-signed-32, -1::little-signed-32, 50_000::little-signed-32,
          2::little-signed-32>>

      bin = bad <> bad <> junk_16()
      {state, _tail} = Scanner.feed(bin, 0x6000, state)

      %{entries: entries} = Scanner.finalize(state)
      assert entries == []
    end

    test "rejects entries with out-of-range arena_id" do
      state = Scanner.initial_state(min_run: 2)
      # arena_id < 15_000 is out of range
      bad = entry(500, 1)
      bin = bad <> bad <> junk_16()
      {state, _tail} = Scanner.feed(bin, 0x7000, state)

      %{entries: entries} = Scanner.finalize(state)
      assert entries == []
    end

    test "rejects entries with out-of-range count" do
      state = Scanner.initial_state(min_run: 2)
      bad = entry(50_000, 10_000)
      bin = bad <> bad <> junk_16()
      {state, _tail} = Scanner.feed(bin, 0x8000, state)

      %{entries: entries} = Scanner.finalize(state)
      assert entries == []
    end
  end
end
