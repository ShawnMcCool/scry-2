defmodule Scry2.Collection.Reader do
  @moduledoc """
  Orchestrates one read of the MTGA card collection from process memory.

  Pipeline (ADR 034 phase 3 / Revision 2026-04-25):

      find MTGA pid (Discovery)
        → list memory maps (Mem.list_maps)
          → discovery self-check (mono + UnityPlayer mapped)
            → walker path (Mem.walk_collection + walker_result_ok?)
            ↓ on walker {:error, _} or self-check failure
              → access channel self-check (MTGA.exe PE "MZ" readable)
                → structural scan across candidate heap regions (Scanner)
                  → scan-result self-check (enough entries, plausible)
                    → summarised read result

  Walker success stamps `reader_confidence: "walker"` and populates
  `wildcards_*`, `gold`, `gems`, `vault_progress`, and
  `mtga_build_hint`. Scanner fallback stamps
  `reader_confidence: "fallback_scan"` and leaves the walker-only
  fields out of the result.

  Pure orchestrator: no GenServer, no ETS. The caller is an Oban job.
  """

  require Scry2.Log, as: Log

  alias Scry2.Collection.Reader.{Discovery, Scanner, SelfCheck}
  alias Scry2.MtgaMemory

  @default_chunk_size 4 * 1024 * 1024
  @default_max_regions 48

  @type entry :: Scanner.entry()

  @type result :: %{
          entries: [entry()],
          entries_start: non_neg_integer(),
          region_start: non_neg_integer(),
          reader_confidence: String.t(),
          card_count: non_neg_integer(),
          total_copies: non_neg_integer()
        }

  @doc """
  Reads one snapshot of the MTGA collection.

  Options:

    * `:mem` — Mem backend module (defaults to the Application config,
      `Scry2.MtgaMemory.impl/0`).
    * `:scanner` — keyword opts forwarded to `Scanner.initial_state/1`,
      notably `:min_run`.
    * `:chunk_size` — bytes per `read_bytes` call (default 4 MiB).
    * `:max_regions` — cap on candidate heap regions (default 48).
    * `:min_scan_entries` — minimum entries a scan must produce for
      `SelfCheck.scan_result_ok?/2` to pass (default 500; tests may
      lower it).

  Returns `{:ok, result}` on success or `{:error, reason}` on any
  pipeline failure. Errors from the self-check gate are
  `{:error, {:check, atom | tuple}}`.
  """
  @spec read(keyword()) :: {:ok, result()} | {:error, term()}
  def read(opts \\ []) do
    mem = Keyword.get(opts, :mem, MtgaMemory.impl())
    scanner_opts = Keyword.get(opts, :scanner, [])
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    max_regions = Keyword.get(opts, :max_regions, @default_max_regions)
    scan_check_opts = Keyword.take(opts, [:min_scan_entries])
    walker_check_opts = Keyword.take(opts, [:min_walker_cards])

    with {:ok, pid} <- Discovery.find_mtga(mem),
         {:ok, maps} <- mem.list_maps(pid),
         :ok <- SelfCheck.discovery_ok?(maps) do
      case try_walker(mem, pid, walker_check_opts) do
        {:ok, walker_result} ->
          {:ok, walker_result}

        {:error, reason} ->
          Log.info(:ingester, fn ->
            "walker fell back to scanner: #{inspect(reason)}"
          end)

          run_scanner_path(mem, pid, maps, scanner_opts, chunk_size, max_regions, scan_check_opts)
      end
    end
  end

  defp try_walker(mem, pid, walker_check_opts) do
    with {:ok, snapshot} <- mem.walk_collection(pid),
         :ok <- SelfCheck.walker_result_ok?(snapshot, walker_check_opts) do
      {:ok, summarize_walker(snapshot)}
    end
  end

  defp run_scanner_path(mem, pid, maps, scanner_opts, chunk_size, max_regions, scan_check_opts) do
    with :ok <- SelfCheck.access_channel_ok?(mem, pid, maps),
         {:ok, finding} <- scan_heap(mem, pid, maps, scanner_opts, chunk_size, max_regions),
         :ok <- SelfCheck.scan_result_ok?(finding, scan_check_opts) do
      {:ok, summarize(finding)}
    end
  end

  defp summarize_walker(%{
         cards: cards,
         wildcards: %{common: c, uncommon: u, rare: r, mythic: m},
         gold: gold,
         gems: gems,
         vault_progress: vault,
         build_hint: build_hint
       }) do
    total_copies = Enum.reduce(cards, 0, fn {_, count}, acc -> acc + count end)

    %{
      entries: cards,
      card_count: length(cards),
      total_copies: total_copies,
      reader_confidence: "walker",
      wildcards_common: c,
      wildcards_uncommon: u,
      wildcards_rare: r,
      wildcards_mythic: m,
      gold: gold,
      gems: gems,
      vault_progress: vault,
      mtga_build_hint: build_hint
    }
  end

  # --- scan orchestration ---

  defp scan_heap(mem, pid, maps, scanner_opts, chunk_size, max_regions) do
    candidates =
      maps
      |> Enum.filter(&rw_anon?/1)
      |> Enum.filter(fn m -> m.end_addr - m.start >= chunk_size end)
      |> Enum.sort_by(fn m -> m.end_addr - m.start end, :desc)
      |> Enum.take(max_regions)

    findings =
      Enum.flat_map(candidates, fn region ->
        case scan_region(mem, pid, region, scanner_opts, chunk_size) do
          %{entries: []} -> []
          finding -> [Map.put(finding, :region_start, region.start)]
        end
      end)

    case Enum.sort_by(findings, &length(&1.entries), :desc) do
      [best | _] -> {:ok, best}
      [] -> {:error, :no_cards_array_found}
    end
  end

  defp rw_anon?(%{perms: perms, path: path}) do
    String.starts_with?(perms, "rw") and (is_nil(path) or path == "")
  end

  defp scan_region(mem, pid, region, scanner_opts, chunk_size) do
    state = Scanner.initial_state(scanner_opts)
    stream_chunks(mem, pid, region, region.start, <<>>, state, chunk_size)
  end

  defp stream_chunks(_mem, _pid, region, pos, _carry, state, _chunk_size)
       when pos >= region.end_addr do
    Scanner.finalize(state)
  end

  defp stream_chunks(mem, pid, region, pos, carry, state, chunk_size) do
    to_read = min(region.end_addr - pos, chunk_size)

    # VA of the first byte of `combined` = position of the carry bytes,
    # which came from the tail of the previous chunk.
    combined_va = pos - byte_size(carry)

    case mem.read_bytes(pid, pos, to_read) do
      {:ok, data} ->
        combined = <<carry::binary, data::binary>>
        {state, tail} = Scanner.feed(combined, combined_va, state)
        stream_chunks(mem, pid, region, pos + to_read, tail, state, chunk_size)

      # Unmapped or otherwise inaccessible page inside an otherwise-mapped
      # region: drop the carry and advance. Matches the POC's EIO handling.
      {:error, _reason} ->
        stream_chunks(mem, pid, region, pos + to_read, <<>>, state, chunk_size)
    end
  end

  defp summarize(%{entries: entries, entries_start: entries_start, region_start: region_start}) do
    total_copies = Enum.reduce(entries, 0, fn {_, count}, acc -> acc + count end)

    %{
      entries: entries,
      entries_start: entries_start,
      region_start: region_start,
      reader_confidence: "fallback_scan",
      card_count: length(entries),
      total_copies: total_copies
    }
  end
end
