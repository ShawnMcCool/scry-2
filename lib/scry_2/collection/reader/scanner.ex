defmodule Scry2.Collection.Reader.Scanner do
  @moduledoc """
  Pure structural scanner for Mono `Dictionary<int,int>` entries arrays.

  Port of `experiments/feasibility_elixir/scan.exs`: pattern-matches
  16-byte windows and keeps the longest run of plausible entries
  observed. Calls are chunked and streaming via `feed/3` + `finalize/1`.

  An entry is the canonical Mono layout of
  `{int32 hash_code; int32 next; TKey key; TValue value}` which for
  `Dictionary<int,int>` is exactly 16 bytes. The scanner validates:

    * hash_code == (key & 0x7FFFFFFF) — Mono's .NET-style hash on int keys
    * 15_000 ≤ arena_id ≤ 250_000 — empirical range of MTGA card ids
    * 0 ≤ count ≤ 4_000 — reasonable owned-copy cap
    * -1 ≤ next ≤ 1_000_000 — the Mono Dict "next" linked-list pointer

  Empty slots are recognised (hash_code == -1) so runs can span them
  without breaking.

  BEAM's sub-binary optimisation makes `rest::binary` an O(1) reference
  per 16-byte window; the scanner is allocation-free per iteration
  aside from the running accumulator list.
  """

  import Bitwise

  @entry_size 16
  @default_min_run 2000

  @type arena_id :: integer()
  @type count :: integer()
  @type entry :: {arena_id(), count()}

  @typedoc """
  `{cur_len, cur_acc, cur_start, best_acc, best_start, min_run}`.

  Internal to the scanner; treat as opaque. `cur_*` track the run in
  progress; `best_*` the longest qualifying run seen so far.
  """
  @opaque scan_state ::
            {non_neg_integer(), [entry()], non_neg_integer() | nil, [entry()],
             non_neg_integer() | nil, pos_integer()}

  @doc """
  Initial state for a scan. `min_run:` tunes the smallest run length
  that counts as "the cards dictionary" (default #{@default_min_run}).
  """
  @spec initial_state(keyword()) :: scan_state()
  def initial_state(opts \\ []) do
    min_run = Keyword.get(opts, :min_run, @default_min_run)
    {0, [], nil, [], nil, min_run}
  end

  @doc """
  Feeds `chunk` into the scanner, starting at virtual address `va`.

  Returns `{new_state, tail_bytes}`; `tail_bytes` is the unconsumed
  suffix (smaller than one entry) that must be prepended to the next
  chunk before the next call.
  """
  @spec feed(binary(), non_neg_integer(), scan_state()) :: {scan_state(), binary()}
  def feed(chunk, va, state) do
    scan_bin(chunk, va, state)
  end

  @doc """
  Closes the scan and returns the best run observed, flushing any
  still-in-progress run that qualifies.
  """
  @spec finalize(scan_state()) :: %{
          entries: [entry()],
          entries_start: non_neg_integer() | nil
        }
  def finalize({cur_len, cur_acc, cur_start, best_acc, best_start, min_run}) do
    {acc, start} =
      if cur_len >= min_run and length(cur_acc) > length(best_acc) do
        {cur_acc, cur_start}
      else
        {best_acc, best_start}
      end

    %{entries: Enum.reverse(acc), entries_start: start}
  end

  # --- scanner core ---

  defp scan_bin(
         <<hash::little-signed-32, next::little-signed-32, key::little-signed-32,
           value::little-signed-32, rest::binary>>,
         va,
         {cur_len, cur_acc, cur_start, best_acc, best_start, min_run}
       ) do
    cond do
      used_slot?(hash, key, value, next) ->
        cur_start = if cur_len == 0, do: va, else: cur_start

        scan_bin(
          rest,
          va + @entry_size,
          {cur_len + 1, [{key, value} | cur_acc], cur_start, best_acc, best_start, min_run}
        )

      empty_slot?(hash, next) ->
        cur_start = if cur_len == 0, do: va, else: cur_start

        scan_bin(
          rest,
          va + @entry_size,
          {cur_len + 1, cur_acc, cur_start, best_acc, best_start, min_run}
        )

      true ->
        {best_acc, best_start} =
          flush(cur_len, cur_acc, cur_start, best_acc, best_start, min_run)

        scan_bin(
          rest,
          va + @entry_size,
          {0, [], nil, best_acc, best_start, min_run}
        )
    end
  end

  defp scan_bin(tail, _va, state) when byte_size(tail) < @entry_size do
    {state, tail}
  end

  defp flush(cur_len, cur_acc, cur_start, best_acc, best_start, min_run) do
    if cur_len >= min_run and length(cur_acc) > length(best_acc) do
      {cur_acc, cur_start}
    else
      {best_acc, best_start}
    end
  end

  defp used_slot?(hash, key, value, next) do
    key >= 15_000 and key <= 250_000 and
      value >= 0 and value <= 4_000 and
      next >= -1 and next <= 1_000_000 and
      hash == band(key, 0x7FFFFFFF)
  end

  defp empty_slot?(hash, next) do
    hash == -1 and next >= -1 and next <= 10_000_000
  end
end
