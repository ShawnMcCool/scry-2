defmodule Scry2.MtgaMemory.SelfTest do
  @moduledoc """
  Runs every memory-reader walk against the live MTGA process and
  produces a "what works / what doesn't" report.

  The reader is not monolithic — it's eight independent walks
  (`walk_collection`, `walk_match_info`, `walk_match_board`,
  `walk_mastery`, `walk_events`, `walk_account`, `walk_cosmetics`,
  `walk_environment`) over a shared discovery base (Mono DLL → root
  domain → image enumeration → class anchors → chain traversal). After
  an MTGA client update shifts Mono struct offsets, some walks can break
  while others keep working.

  This self-test runs all eight, classifies each as `:ok` / `:empty` /
  `:error` (with the precise failure reason), and derives a
  plain-language overall `Diagnosis`. `:empty` means the walk worked but
  there was nothing to read right now (no active match, between mastery
  seasons, not logged in) — it is **not** a failure.

  Surfaced on `/operations/mtga-memory`, via the build-change banner's
  failure state, and from `Scry2.Diagnostics.reader_self_test/0` in a
  remote shell. See `.claude/skills/mono-memory-reader/SKILL.md`.
  """

  alias Scry2.Collection
  alias Scry2.Collection.Reader.Discovery
  alias Scry2.MtgaMemory
  alias Scry2.MtgaMemory.SelfTest.{Diagnosis, Report, WalkResult}
  alias Scry2.MtgaMemory.WalkError

  @walks ~w(collection match_info match_board mastery events account cosmetics environment)a

  @doc "The fixed list of walks the self-test exercises, in report order."
  @spec walks() :: [atom()]
  def walks, do: @walks

  @doc """
  Run the full self-test against the live MTGA process. Returns a
  `Report`. When no MTGA process is found, returns a report with
  `mtga_running: false` and an `:mtga_not_running` diagnosis (no walks
  attempted).
  """
  @spec run(module(), keyword()) :: Report.t()
  def run(mem \\ MtgaMemory.impl(), _opts \\ []) do
    ran_at = DateTime.utc_now()

    case Discovery.find_mtga(mem) do
      {:error, _reason} ->
        %Report{
          mtga_running: false,
          pid: nil,
          build_hint: nil,
          reader_version: nil,
          ran_at: ran_at,
          walks: [],
          diagnosis: diagnose([], false)
        }

      {:ok, pid} ->
        pairs = Enum.map(@walks, fn walk -> {walk, run_walk(walk, mem, pid)} end)
        walk_results = Enum.map(pairs, fn {_walk, {result, _raw}} -> result end)
        {build_hint, reader_version} = build_info(pairs)

        %Report{
          mtga_running: true,
          pid: pid,
          build_hint: build_hint,
          reader_version: reader_version,
          ran_at: ran_at,
          walks: walk_results,
          diagnosis: diagnose(walk_results, true)
        }
    end
  end

  # Returns {%WalkResult{}, raw_result} so the caller can pull build_hint
  # / reader_version out of the collection walk's raw payload.
  defp run_walk(walk, mem, pid) do
    t0 = System.monotonic_time(:millisecond)
    raw = invoke(walk, mem, pid)
    elapsed = System.monotonic_time(:millisecond) - t0

    {outcome, reason} = classify(raw)

    result = %WalkResult{
      walk: walk,
      outcome: outcome,
      reason: reason,
      reason_text: reason_text(reason),
      elapsed_ms: elapsed
    }

    {result, raw}
  end

  defp invoke(walk, mem, pid) do
    apply_walk(walk, mem, pid)
  rescue
    error -> {:error, {:crashed, Exception.message(error)}}
  catch
    kind, value -> {:error, {:crashed, "#{kind}: #{inspect(value)}"}}
  end

  defp apply_walk(:collection, mem, pid), do: mem.walk_collection(pid, [])
  defp apply_walk(:match_info, mem, pid), do: mem.walk_match_info(pid)
  defp apply_walk(:match_board, mem, pid), do: mem.walk_match_board(pid)
  defp apply_walk(:mastery, mem, pid), do: mem.walk_mastery(pid)
  defp apply_walk(:events, mem, pid), do: mem.walk_events(pid)
  defp apply_walk(:account, mem, pid), do: mem.walk_account(pid)
  defp apply_walk(:cosmetics, mem, pid), do: mem.walk_cosmetics(pid)
  defp apply_walk(:environment, mem, pid), do: mem.walk_environment(pid)

  defp classify({:ok, nil}), do: {:empty, nil}
  defp classify({:ok, _data}), do: {:ok, nil}
  defp classify({:error, reason}), do: {:error, reason}
  defp classify(other), do: {:error, {:unexpected, other}}

  defp reason_text(nil), do: nil
  defp reason_text({:crashed, message}), do: "Reader crashed: #{message}"
  defp reason_text(reason), do: WalkError.translate(reason)

  defp build_info(pairs) do
    collection_raw =
      Enum.find_value(pairs, fn
        {:collection, {_result, {:ok, %{} = data}}} -> data
        _ -> nil
      end)

    case collection_raw do
      %{build_hint: build_hint, reader_version: reader_version} ->
        {build_hint, reader_version}

      _ ->
        from_latest_snapshot()
    end
  end

  defp from_latest_snapshot do
    case Collection.current() do
      %{mtga_build_hint: build_hint, reader_version: reader_version} ->
        {build_hint, reader_version}

      _ ->
        {nil, nil}
    end
  end

  @doc """
  Derive the overall diagnosis from the per-walk results. Pure.

  `pid_present?` is false only when no MTGA process was found.
  """
  @spec diagnose([WalkResult.t()], boolean()) :: Diagnosis.t()
  def diagnose(_walk_results, false) do
    %Diagnosis{
      status: :mtga_not_running,
      headline: "MTGA isn't running",
      detail: "Start MTGA, sign in, then run the self-test again.",
      broken: [],
      working: []
    }
  end

  def diagnose(walk_results, true) do
    errors = Enum.filter(walk_results, &(&1.outcome == :error))
    all_errored? = errors != [] and length(errors) == length(walk_results)

    cond do
      errors == [] ->
        %Diagnosis{
          status: :healthy,
          headline: "Memory reader fully healthy",
          detail: "Every reader walk returned data (or had nothing to read right now).",
          broken: [],
          working: walk_names(walk_results)
        }

      all_errored? and all_reason?(errors, :mono_dll_not_found) ->
        %Diagnosis{
          status: :runtime_not_ready,
          headline: "MTGA is running but its runtime hasn't finished loading",
          detail:
            "No walks could reach MTGA's Mono runtime yet. This is normal right after launch — wait a few seconds and try again.",
          broken: walk_names(errors),
          working: []
        }

      all_errored? and all_shared_chain?(errors) ->
        %Diagnosis{
          status: :deep_break,
          headline:
            "The reader can't enter MTGA's runtime — offsets need updating for this build",
          detail:
            "Every walk failed at the shared discovery step, which means the memory layout shifted in this MTGA build. Scry2 needs an update before any reads will work.",
          broken: walk_names(errors),
          working: []
        }

      true ->
        broken = walk_names(errors)
        working = walk_names(Enum.filter(walk_results, &(&1.outcome != :error)))

        %Diagnosis{
          status: :partial,
          headline: "Some reads work, some are broken",
          detail:
            "Working: #{format_list(working)}. Broken: #{format_list(broken)}. The broken walks likely need updated offsets for this MTGA build.",
          broken: broken,
          working: working
        }
    end
  end

  defp walk_names(results), do: Enum.map(results, & &1.walk)

  defp all_reason?(errors, reason), do: Enum.all?(errors, &(&1.reason == reason))

  defp all_shared_chain?(errors), do: Enum.all?(errors, &WalkError.shared_chain?(&1.reason))

  defp format_list([]), do: "none"
  defp format_list(walks), do: walks |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")

  @doc """
  Render a `Report` as a copyable plain-text block suitable for pasting
  into a bug report.
  """
  @spec to_text(Report.t()) :: String.t()
  def to_text(%Report{} = report) do
    header = [
      "# Scry2 reader self-test",
      "",
      "MTGA running: #{report.mtga_running}",
      "MTGA build:   #{report.build_hint || "unknown"}",
      "Reader:       #{report.reader_version || "unknown"}",
      "Ran at:       #{DateTime.to_iso8601(report.ran_at)}",
      "Diagnosis:    #{report.diagnosis.headline}",
      "",
      report.diagnosis.detail
    ]

    walk_lines =
      case report.walks do
        [] ->
          ["", "(no walks attempted)"]

        walks ->
          ["", "Walks:" | Enum.map(walks, &walk_line/1)]
      end

    (header ++ walk_lines) |> Enum.join("\n")
  end

  defp walk_line(%WalkResult{walk: walk, outcome: :ok}),
    do: "  [ok]     #{walk}"

  defp walk_line(%WalkResult{walk: walk, outcome: :empty}),
    do: "  [empty]  #{walk} (nothing to read right now)"

  defp walk_line(%WalkResult{walk: walk, outcome: :error, reason_text: reason_text}),
    do: "  [BROKEN] #{walk} — #{reason_text}"
end
