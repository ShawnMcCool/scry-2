defmodule Scry2.MatchEconomy do
  @moduledoc """
  Per-match economy delta + log reconciliation projection. See ADR-036.

  Public API:

    * `upsert_summary!/1` — insert-or-update a `Summary` row by `mtga_match_id`
    * `get_summary/1` — load a single summary
    * `recent_summaries/1` — last N matches by `ended_at`, with optional offset/since/until
    * `count_summaries/1` — count of summaries matching the given filter
    * `timeline/1` — daily-rollup aggregation for the timeline page
  """

  import Ecto.Query
  alias Scry2.Repo
  alias Scry2.MatchEconomy.Summary

  @enabled_settings_key "match_economy_capture_enabled"

  @doc "Settings key for the match-economy capture feature flag."
  @spec enabled_settings_key() :: String.t()
  def enabled_settings_key, do: @enabled_settings_key

  @doc """
  Read the current value of the match-economy capture feature flag.
  Defaults to true when the setting is absent.
  """
  @spec capture_enabled?() :: boolean()
  def capture_enabled? do
    case Scry2.Settings.get(@enabled_settings_key) do
      nil -> true
      true -> true
      "true" -> true
      false -> false
      "false" -> false
      _ -> true
    end
  end

  @doc """
  Idempotent upsert by `mtga_match_id`.
  """
  @spec upsert_summary!(map()) :: Summary.t()
  def upsert_summary!(%{mtga_match_id: id} = attrs) when is_binary(id) do
    case Repo.get_by(Summary, mtga_match_id: id) do
      nil ->
        %Summary{}
        |> Summary.changeset(attrs)
        |> Repo.insert!()

      existing ->
        existing
        |> Summary.changeset(attrs)
        |> Repo.update!()
    end
  end

  @spec get_summary(String.t()) :: Summary.t() | nil
  def get_summary(mtga_match_id) when is_binary(mtga_match_id) do
    Repo.get_by(Summary, mtga_match_id: mtga_match_id)
  end

  @spec recent_summaries(keyword()) :: [Summary.t()]
  def recent_summaries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    offset = Keyword.get(opts, :offset, 0)
    since = Keyword.get(opts, :since)
    until_dt = Keyword.get(opts, :until)

    base =
      from(s in Summary,
        where: not is_nil(s.ended_at),
        order_by: [desc: s.ended_at]
      )

    base = if since, do: from(s in base, where: s.ended_at >= ^since), else: base
    base = if until_dt, do: from(s in base, where: s.ended_at <= ^until_dt), else: base

    base |> limit(^limit) |> offset(^offset) |> Repo.all()
  end

  @doc "Returns the count of summaries matching the given filter (mirrors recent_summaries/1)."
  @spec count_summaries(keyword()) :: non_neg_integer()
  def count_summaries(opts \\ []) do
    since = Keyword.get(opts, :since)
    until_dt = Keyword.get(opts, :until)

    base = from(s in Summary, where: not is_nil(s.ended_at))
    base = if since, do: from(s in base, where: s.ended_at >= ^since), else: base
    base = if until_dt, do: from(s in base, where: s.ended_at <= ^until_dt), else: base

    Repo.aggregate(base, :count)
  end

  @doc """
  Daily roll-up for the timeline page. Returns a list of
  `%{date: Date.t(), gold: integer(), gems: integer(),
     wildcards_common/uncommon/rare/mythic: integer(),
     match_count: integer()}` buckets, ordered by date ascending.
  """
  @spec timeline(keyword()) :: [map()]
  def timeline(opts \\ []) do
    since = Keyword.get(opts, :since)
    until_dt = Keyword.get(opts, :until)

    base = from(s in Summary, where: not is_nil(s.ended_at))
    base = if since, do: from(s in base, where: s.ended_at >= ^since), else: base
    base = if until_dt, do: from(s in base, where: s.ended_at <= ^until_dt), else: base

    rows =
      base
      |> Repo.all()
      |> Enum.group_by(&DateTime.to_date(&1.ended_at))

    rows
    |> Enum.map(fn {date, summaries} ->
      %{
        date: date,
        gold: sum_field(summaries, :memory_gold_delta),
        gems: sum_field(summaries, :memory_gems_delta),
        wildcards_common: sum_field(summaries, :memory_wildcards_common_delta),
        wildcards_uncommon: sum_field(summaries, :memory_wildcards_uncommon_delta),
        wildcards_rare: sum_field(summaries, :memory_wildcards_rare_delta),
        wildcards_mythic: sum_field(summaries, :memory_wildcards_mythic_delta),
        match_count: length(summaries)
      }
    end)
    |> Enum.sort_by(& &1.date, Date)
  end

  defp sum_field(rows, key) do
    Enum.reduce(rows, 0, fn row, acc -> acc + (Map.get(row, key) || 0) end)
  end
end
