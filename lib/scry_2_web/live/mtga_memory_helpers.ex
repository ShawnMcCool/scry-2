defmodule Scry2Web.MtgaMemoryHelpers do
  @moduledoc """
  Pure formatters and shape-shapers for `Scry2Web.MtgaMemoryLive`.

  Per ADR-013, all non-trivial logic in the diagnostics LiveView lives
  here so it can be unit-tested with `async: true` and no DB.

  The diagnostics page is the operator's window into the memory-reader
  subsystem: process detection, walker traces with read-count and
  wall-clock measurements, discovery cache state, and ad-hoc
  class/field probes. Every value rendered on that page passes through
  one of these formatters.
  """

  @typedoc "Read-count + budget tuple from the walker's stats NIFs."
  @type stats :: %{reads_used: non_neg_integer(), budget: non_neg_integer()}

  @doc """
  Format `reads_used / budget` as a human-readable percent. Rounds to
  one decimal place; flags ≥ 80% as a warning so the diagnostics page
  can surface drift before the next budget regression.
  """
  @spec format_stats(stats()) :: String.t()
  def format_stats(%{reads_used: used, budget: budget}) when budget > 0 do
    pct = Float.round(used / budget * 100, 1)
    "#{used} / #{budget} (#{pct}%)"
  end

  def format_stats(%{reads_used: used, budget: 0}), do: "#{used} / 0"

  @doc "Percentage of budget used, as a float (0.0–100.0+)."
  @spec usage_percent(stats()) :: float()
  def usage_percent(%{reads_used: used, budget: budget}) when budget > 0 do
    Float.round(used / budget * 100, 1)
  end

  def usage_percent(_), do: 0.0

  @doc """
  Classifies budget usage into a UI-ready band. The thresholds are
  meaningful: ≥80% means the next MTGA upgrade could push us over the
  ceiling, so the operator should re-measure before shipping. ≥50% is
  a soft warning — fine today, watch over time.
  """
  @spec usage_band(stats()) :: :ok | :watch | :warning | :critical
  def usage_band(stats) do
    case usage_percent(stats) do
      pct when pct >= 100.0 -> :critical
      pct when pct >= 80.0 -> :warning
      pct when pct >= 50.0 -> :watch
      _ -> :ok
    end
  end

  @doc "DaisyUI badge class for a usage band."
  @spec band_class(:ok | :watch | :warning | :critical) :: String.t()
  def band_class(:critical), do: "badge badge-soft badge-error"
  def band_class(:warning), do: "badge badge-soft badge-warning"
  def band_class(:watch), do: "badge badge-soft badge-info"
  def band_class(:ok), do: "badge badge-soft badge-success"

  @doc """
  Render the {result, _stats} tuple a stats NIF returns into a short
  status string. We render the *shape* of the result (ok-nil vs
  ok-some vs error) — actual payload extraction is the LiveView's job
  via the per-chain summarisers.
  """
  @spec format_outcome(any()) :: String.t()
  def format_outcome({:ok, nil}), do: "ok (no data)"
  def format_outcome({:ok, _}), do: "ok"
  def format_outcome({:error, reason}), do: "error: #{inspect(reason)}"
  def format_outcome(other), do: "unexpected: #{inspect(other)}"

  @doc "DaisyUI badge class for an outcome (matches `format_outcome/1`)."
  @spec outcome_class(any()) :: String.t()
  def outcome_class({:ok, nil}), do: "badge badge-soft badge-info"
  def outcome_class({:ok, _}), do: "badge badge-soft badge-success"
  def outcome_class({:error, _}), do: "badge badge-soft badge-error"
  def outcome_class(_), do: "badge badge-soft badge-warning"

  @doc """
  Summarise a `walk_match_info` payload. Returns a short string
  describing the opponent or the reason no opponent is visible. Empty
  string when the result was an error.
  """
  @spec match_info_summary(any()) :: String.t()
  def match_info_summary({:ok, nil}), do: "no match in progress"

  def match_info_summary({:ok, snap}) when is_map(snap) do
    opp = Map.get(snap, :opponent, %{})
    name = Map.get(opp, :screen_name) || Map.get(opp, :name) || ""
    name = if name == "" or name == "Opponent", do: "(none)", else: name
    rank = format_rank(opp)
    "opponent: #{name}#{rank}"
  end

  def match_info_summary(_), do: ""

  defp format_rank(opp) do
    case {Map.get(opp, :ranking_class), Map.get(opp, :ranking_tier)} do
      {nil, _} -> ""
      {_, nil} -> ""
      {0, _} -> ""
      {class, tier} -> " — rank class=#{class} tier=#{tier}"
    end
  end

  @doc """
  Summarise a `walk_match_board` payload. Returns "zones=N, cards=M"
  or a "no scene" string when MatchSceneManager.Instance was nil
  (post-match teardown).
  """
  @spec match_board_summary(any()) :: String.t()
  def match_board_summary({:ok, nil}), do: "no match scene"

  def match_board_summary({:ok, %{zones: zones}}) when is_list(zones) do
    cards = Enum.reduce(zones, 0, fn z, acc -> acc + length(z.arena_ids) end)
    "zones=#{length(zones)}, cards=#{cards}"
  end

  def match_board_summary(_), do: ""

  @doc """
  Format an elapsed time in milliseconds with a sensible unit. Sub-ms
  values still render as `<1 ms` so the UI stays consistent.
  """
  @spec format_elapsed_ms(integer()) :: String.t()
  def format_elapsed_ms(ms) when ms < 1, do: "<1 ms"
  def format_elapsed_ms(ms), do: "#{ms} ms"

  @doc """
  Truncate a long cmdline for display. Keeps both ends — the binary
  path and the trailing argv entries — so the operator can still see
  what's running.
  """
  @spec truncate_cmdline(String.t() | nil, pos_integer()) :: String.t()
  def truncate_cmdline(nil, _), do: ""
  def truncate_cmdline("", _), do: ""

  def truncate_cmdline(cmdline, max) when byte_size(cmdline) <= max, do: cmdline

  def truncate_cmdline(cmdline, max) when max > 10 do
    half = div(max - 5, 2)
    head = binary_part(cmdline, 0, half)
    tail = binary_part(cmdline, byte_size(cmdline) - half, half)
    head <> " ... " <> tail
  end

  def truncate_cmdline(cmdline, _), do: String.slice(cmdline, 0, 64)

  @doc """
  Group cache snapshot rows into a UI-ready list. The Rust NIF
  returns `[{pid, "mono,domain,images,PAPA"}]`; we split the slot list
  back into a list of strings for the table.
  """
  @spec normalise_cache_snapshot([{non_neg_integer(), String.t()}]) ::
          [%{pid: non_neg_integer(), slots: [String.t()]}]
  def normalise_cache_snapshot(rows) when is_list(rows) do
    Enum.map(rows, fn {pid, slots_csv} ->
      %{
        pid: pid,
        slots:
          slots_csv
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
      }
    end)
  end
end
