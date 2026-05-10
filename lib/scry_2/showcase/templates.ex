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

  def render_body(%Insight{body_template: _}), do: nil

  defp pct(nil), do: "0%"
  defp pct(rate) when is_number(rate), do: "#{round(rate * 100)}%"

  defp pct_abs(nil), do: "0"
  defp pct_abs(rate) when is_number(rate), do: "#{abs(round(rate * 100))}"

  defp humanize_event_type(nil), do: "Event"

  defp humanize_event_type(s) when is_binary(s) do
    s
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
