defmodule Scry2.Showcase.Templates do
  @moduledoc """
  Renders insight title and body strings from `:title_template` /
  `:body_template` keys carried on a persisted `%Insight{}`.

  Wording is fixed per detector type — only the numbers from
  `:stats` and `:measurements` vary. No detector ever generates prose;
  this module is the only place strings are produced from insights.

  Adding a template:

    1. Add a function clause matching the new template key.
    2. Read measurements via `insight.measurements[...]`.
    3. Build a string. Keep it factual; cite numbers, not narrative.
  """

  alias Scry2.Insights.Insight

  @doc """
  Returns the rendered title string for an insight, or a clearly-marked
  fallback if the template key isn't registered.
  """
  @spec render_title(Insight.t()) :: String.t()
  def render_title(%Insight{title_template: "on_play_vs_on_draw.title"}),
    do: "On the play vs on the draw"

  def render_title(%Insight{
        title_template: "event_roi.title",
        measurements: m
      }),
      do: "#{humanize_event_type(m["event_type"])} is gem-negative"

  def render_title(%Insight{title_template: "mulligan_outcome.title"}),
    do: "Mulligan tax"

  def render_title(%Insight{title_template: "bo1_vs_bo3_gap.title"}),
    do: "BO1 vs BO3 split"

  def render_title(%Insight{title_template: "p1p1_rarity.title"}),
    do: "First-pick rarity bias"

  def render_title(%Insight{title_template: "format_baseline.title", measurements: m}),
    do: "Best format: #{humanize_format(m["best_format"])}"

  def render_title(%Insight{title_template: "crafting_velocity.title"}),
    do: "This week's crafting"

  def render_title(%Insight{title_template: "deck_heater.title", measurements: m}),
    do: "#{deck_label(m["deck_name"])} on a heater"

  def render_title(%Insight{title_template: "deck_color_outlier.title", measurements: m}) do
    direction = if m["direction"] == "above", do: "above", else: "below"
    "#{m["colors"]} #{direction} your baseline"
  end

  def render_title(%Insight{title_template: "rank_milestone.title", measurements: m}),
    do: "You reached #{m["class"]} #{humanize_rank_format(m["format"])}"

  def render_title(%Insight{title_template: "draft_conversion_rate.title", measurements: m}),
    do: "Draft conversion: #{format_avg(m["avg_wins"])} wins per run"

  def render_title(%Insight{title_template: "weekend_warrior.title", measurements: m}) do
    case m["direction"] do
      "weekend" -> "You're a weekend warrior"
      "weeknight" -> "You're a weeknight grinder"
      _ -> "Play schedule pattern"
    end
  end

  def render_title(%Insight{title_template: key}),
    do: "(missing title template: #{key})"

  @doc """
  Returns the rendered body string for an insight, or `nil` if the
  insight has no body template.
  """
  @spec render_body(Insight.t()) :: String.t() | nil
  def render_body(%Insight{body_template: nil}), do: nil

  def render_body(%Insight{
        body_template: "on_play_vs_on_draw.body",
        measurements: m
      }) do
    play = pct(m["on_play_wr"])
    draw = pct(m["on_draw_wr"])
    gap = pct_abs(m["gap"])
    n = m["total_n"] || 0
    "#{play} on the play, #{draw} on the draw. A #{gap}-point gap on #{n} matches."
  end

  def render_body(%Insight{
        body_template: "event_roi.body",
        measurements: m
      }) do
    days = m["lookback_days"] || 30
    n = m["events_count"] || 0
    spent = m["gems_spent"] || 0
    earned = m["gems_earned"] || 0
    net = m["net_gems"] || 0

    "Over #{days} days, #{n} entries: spent #{spent} gems, earned #{earned}. Net #{net}."
  end

  def render_body(%Insight{body_template: "mulligan_outcome.body", measurements: m}) do
    kept = pct(m["kept_wr"])
    mull = pct(m["mull_wr"])
    n = m["total_n"] || 0
    "#{kept} on a kept hand, #{mull} after a mulligan. n=#{n} matches."
  end

  def render_body(%Insight{body_template: "bo1_vs_bo3_gap.body", measurements: m}) do
    bo1 = pct(m["bo1_wr"])
    bo3 = pct(m["bo3_wr"])
    "#{bo1} in BO1 (n=#{m["bo1_n"] || 0}), #{bo3} in BO3 (n=#{m["bo3_n"] || 0})."
  end

  def render_body(%Insight{body_template: "p1p1_rarity.body", measurements: m}) do
    rare = pct(m["rare_wr"])
    other = pct(m["other_wr"])

    "Rare/mythic P1P1 → #{rare} draft WR. Common/uncommon P1P1 → #{other}. n=#{m["total_n"] || 0} drafts."
  end

  def render_body(%Insight{body_template: "format_baseline.body", measurements: m}) do
    best = humanize_format(m["best_format"])
    wr = pct(m["best_wr"])
    n = m["best_n"] || 0
    "#{wr} in #{best} (n=#{n}) across #{m["format_count"] || 0} formats with significant samples."
  end

  def render_body(%Insight{body_template: "crafting_velocity.body", measurements: m}) do
    days = m["lookback_days"] || 7
    mythics = m["mythics"] || 0
    rares = m["rares"] || 0
    uncommons = m["uncommons"] || 0
    "Last #{days} days: #{mythics} mythic, #{rares} rare, #{uncommons} uncommon wildcards spent."
  end

  def render_body(%Insight{body_template: "deck_heater.body", measurements: m}) do
    deck = deck_label(m["deck_name"])
    deck_wr = pct(m["deck_wr"])
    base_wr = pct(m["baseline_wr"])
    n = m["deck_n"] || 0
    days = m["lookback_days"] || 7

    "#{deck} is at #{deck_wr} over the last #{days}d (n=#{n}) vs your overall #{base_wr} baseline. Statistically significant."
  end

  def render_body(%Insight{body_template: "deck_color_outlier.body", measurements: m}) do
    colors = m["colors"] || "?"
    combo_wr = pct(m["combo_wr"])
    base_wr = pct(m["baseline_wr"])
    n = m["combo_n"] || 0

    "#{combo_wr} with #{colors} (n=#{n}) vs your overall #{base_wr} baseline. Statistically significant."
  end

  def render_body(%Insight{body_template: "weekend_warrior.body", measurements: m}) do
    weekend_n = m["weekend_n"] || 0
    weekday_n = m["weekday_n"] || 0
    total = weekend_n + weekday_n
    weekend_pct = if total > 0, do: "#{round(weekend_n / total * 100)}%", else: "0%"

    "#{weekend_n} of your #{total} matches (#{weekend_pct}) happened on Saturday or Sunday — well off the uniform 29% baseline."
  end

  def render_body(%Insight{body_template: "draft_conversion_rate.body", measurements: m}) do
    n = m["drafts_n"] || 0
    avg = format_avg(m["avg_wins"])
    trophies = m["trophies"] || 0
    trophy_str = if trophies == 1, do: "1 trophy", else: "#{trophies} trophies"

    "Last #{n} drafts averaged #{avg} wins per run, with #{trophy_str}."
  end

  def render_body(%Insight{body_template: "rank_milestone.body", measurements: m}) do
    class = m["class"] || "?"
    format = humanize_rank_format(m["format"])
    days = m["days_ago"] || 0
    promotions = m["promotions_this_season"] || 0

    when_str =
      if days == 0, do: "today", else: "#{days} day#{if days == 1, do: "", else: "s"} ago"

    "Crossed into #{class} #{format} #{when_str} — #{promotions} class promotion#{if promotions == 1, do: "", else: "s"} this season."
  end

  def render_body(%Insight{body_template: _}), do: nil

  defp pct(nil), do: "0%"
  defp pct(rate) when is_number(rate), do: "#{round(rate * 100)}%"

  defp pct_abs(nil), do: "0"
  defp pct_abs(rate) when is_number(rate), do: "#{abs(round(rate * 100))}"

  defp humanize_format("Traditional"), do: "BO3"
  defp humanize_format("Constructed"), do: "BO1 Constructed"
  defp humanize_format("Limited"), do: "Limited"
  defp humanize_format(s) when is_binary(s), do: s
  defp humanize_format(_), do: "Unknown"

  defp humanize_rank_format("constructed"), do: "Constructed"
  defp humanize_rank_format("limited"), do: "Limited"
  defp humanize_rank_format(s) when is_binary(s), do: s
  defp humanize_rank_format(_), do: ""

  defp format_avg(nil), do: "0.0"

  defp format_avg(avg) when is_number(avg),
    do: :erlang.float_to_binary(avg / 1, decimals: 1)

  defp deck_label(nil), do: "A deck"
  defp deck_label(""), do: "A deck"
  defp deck_label(name) when is_binary(name), do: name

  defp humanize_event_type(nil), do: "Event"

  defp humanize_event_type(s) when is_binary(s) do
    s
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
