defmodule Scry2.Showcase.TileTypes.LatestMatch do
  @moduledoc """
  α tease tile for the most recent match.

  Title is factual: result + game count. Meta line carries format, deck
  name, and relative age. No fabricated narrative.

  Activity-mode tile — fires whenever there's at least one match in the
  database. Returns `nil` otherwise.
  """

  alias Scry2.Matches
  alias Scry2.Showcase.TileSpec

  @spec build(keyword()) :: TileSpec.t() | nil
  def build(_opts \\ []) do
    case List.first(Matches.list_matches(limit: 1)) do
      nil -> nil
      match -> render(match)
    end
  end

  defp render(match) do
    %TileSpec{
      kind: :latest_match,
      kind_label: "latest match",
      composition: :activity,
      title: title(match),
      art: nil,
      meta: meta(match),
      target: {:navigate, "/matches/#{match.id}"}
    }
  end

  defp title(match) do
    result = if match.won, do: "WIN", else: "LOSS"
    games = format_games(match.game_results)
    if games == "", do: result, else: "#{result} #{games}"
  end

  defp format_games(%{"wins" => w, "losses" => l}) when is_integer(w) and is_integer(l),
    do: "#{w}-#{l}"

  defp format_games(_), do: ""

  defp meta(match) do
    [
      humanize_format(match.format),
      match.deck_name,
      format_age(match.started_at)
    ]
    |> Enum.reject(&blank?/1)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp humanize_format(nil), do: nil

  defp humanize_format(format) when is_binary(format) do
    format
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_age(nil), do: nil

  defp format_age(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 7 * 86_400 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end
end
