defmodule Scry2.Showcase.TileTypes.Climb do
  @moduledoc """
  α tease tile for the player's current rank.

  Reads the most recent `Scry2.Ranks.Snapshot`. Title is `<class> <level>`
  for the format with the most matches this season; subtitle carries the
  format and rank-record (e.g. "Constructed · 47-32"). Meta carries the
  season ordinal and relative age.

  Activity-mode tile — fires whenever there's at least one rank snapshot
  in the database. Returns `nil` otherwise.
  """

  alias Scry2.Ranks
  alias Scry2.Showcase.TileSpec

  @spec build(keyword()) :: TileSpec.t() | nil
  def build(_opts \\ []) do
    case Ranks.latest_snapshot() do
      nil -> nil
      snapshot -> render(snapshot)
    end
  end

  defp render(snapshot) do
    case pick_format(snapshot) do
      nil ->
        nil

      {format, class, level, wins, losses} ->
        %TileSpec{
          kind: :climb,
          kind_label: "climb",
          composition: :activity,
          title: title(class, level),
          body: subtitle(format, wins, losses),
          art: nil,
          meta: meta(snapshot),
          target: {:navigate, "/ranks"}
        }
    end
  end

  defp pick_format(snap) do
    constructed_n = (snap.constructed_matches_won || 0) + (snap.constructed_matches_lost || 0)
    limited_n = (snap.limited_matches_won || 0) + (snap.limited_matches_lost || 0)

    constructed_present? = present?(snap.constructed_class)
    limited_present? = present?(snap.limited_class)

    cond do
      not constructed_present? and not limited_present? ->
        nil

      limited_present? and (limited_n > constructed_n or not constructed_present?) ->
        {"Limited", snap.limited_class, snap.limited_level, snap.limited_matches_won,
         snap.limited_matches_lost}

      true ->
        {"Constructed", snap.constructed_class, snap.constructed_level,
         snap.constructed_matches_won, snap.constructed_matches_lost}
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp title(nil, _), do: "Unranked"

  defp title(class, level) when is_binary(class) and is_integer(level) do
    "#{class} #{level}"
  end

  defp title(class, _) when is_binary(class), do: class
  defp title(_, _), do: "Unranked"

  defp subtitle(format, nil, nil), do: format
  defp subtitle(format, w, nil), do: "#{format} · #{w}-0"
  defp subtitle(format, nil, l), do: "#{format} · 0-#{l}"
  defp subtitle(format, w, l), do: "#{format} · #{w}-#{l}"

  defp meta(snap) do
    [
      season_label(snap.season_ordinal),
      format_age(snap.occurred_at)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp season_label(nil), do: nil
  defp season_label(n) when is_integer(n), do: "season #{n}"

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
