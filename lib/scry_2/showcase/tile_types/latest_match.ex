defmodule Scry2.Showcase.TileTypes.LatestMatch do
  @moduledoc """
  α tease tile for the most recent match.

  Title is factual: result + game count derived from the player's
  perspective on `match.game_results.results`. Body line carries
  opponent + rank context. Art surfaces deck colors as mana pips when
  available. Meta carries format, deck name, turn count, and relative
  age. No fabricated narrative.

  Activity-mode tile — fires whenever there's at least one match in
  the database. Returns `nil` otherwise.
  """

  import Ecto.Query

  alias Scry2.Decks.GameDraw
  alias Scry2.Matches
  alias Scry2.Repo
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
      body: opponent_line(match),
      art: art_for(match),
      meta: meta(match),
      target: {:navigate, "/matches/#{match.id}"}
    }
  end

  # Card image of most-drawn-by-self card if we have draw data for this match;
  # otherwise fall back to deck-colors mana pips; otherwise nothing.
  defp art_for(match) do
    case top_drawn_arena_id(match.mtga_match_id) do
      nil -> deck_colors_art(match.deck_colors)
      arena_id -> %{type: :card_image, arena_id: arena_id}
    end
  end

  defp top_drawn_arena_id(nil), do: nil

  defp top_drawn_arena_id(mtga_match_id) do
    # `is_self_draw` is nullable in the projector and currently unused, so we
    # don't filter on it. All captured draws are effectively the player's.
    GameDraw
    |> where([d], d.mtga_match_id == ^mtga_match_id and not is_nil(d.card_arena_id))
    |> group_by([d], d.card_arena_id)
    |> select([d], {d.card_arena_id, count(d.id)})
    |> order_by([d], desc: count(d.id))
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      {arena_id, _count} -> arena_id
    end
  end

  defp title(match) do
    result = if match.won, do: "WIN", else: "LOSS"
    games = format_games(match.game_results)
    if games == "", do: result, else: "#{result} #{games}"
  end

  defp format_games(%{"results" => results}) when is_list(results) do
    wins = Enum.count(results, &(Map.get(&1, "won") == true))
    losses = Enum.count(results, &(Map.get(&1, "won") == false))

    if wins == 0 and losses == 0 do
      ""
    else
      "#{wins}-#{losses}"
    end
  end

  defp format_games(_), do: ""

  defp opponent_line(match) do
    name_part =
      cond do
        is_binary(match.opponent_screen_name) and match.opponent_screen_name != "" ->
          "vs #{match.opponent_screen_name}"

        true ->
          nil
      end

    rank_part =
      cond do
        is_binary(match.opponent_rank) and match.opponent_rank != "" ->
          "(#{match.opponent_rank})"

        is_binary(match.player_rank) and match.player_rank != "" ->
          "you: #{match.player_rank}"

        true ->
          nil
      end

    [name_part, rank_part]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp deck_colors_art(colors) when is_binary(colors) and colors != "" do
    %{type: :deck_colors, colors: colors}
  end

  defp deck_colors_art(_), do: nil

  defp meta(match) do
    [
      humanize_format(match.format_type || match.format),
      match.deck_name,
      turn_meta(match.total_turns),
      format_age(match.started_at)
    ]
    |> Enum.reject(&blank?/1)
  end

  defp turn_meta(nil), do: nil
  defp turn_meta(0), do: nil
  defp turn_meta(n) when is_integer(n), do: "#{n} turns"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp humanize_format(nil), do: nil
  defp humanize_format("Traditional"), do: "Traditional"
  defp humanize_format("Constructed"), do: "Constructed"
  defp humanize_format("Limited"), do: "Limited"

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
