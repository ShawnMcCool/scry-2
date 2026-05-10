defmodule Scry2.Showcase.TileTypes.LatestDraft do
  @moduledoc """
  α tease tile for the most recent draft.

  Title is factual: record + set code (or just record if set unknown).
  Subtitle carries the event name. Meta carries trophy/incomplete state
  and relative age. No fabricated narrative.

  Activity-mode tile — fires whenever there's at least one draft in
  the database. Returns `nil` otherwise.
  """

  import Ecto.Query

  alias Scry2.Drafts
  alias Scry2.Drafts.Pick
  alias Scry2.Repo
  alias Scry2.Showcase.TileSpec

  @spec build(keyword()) :: TileSpec.t() | nil
  def build(_opts \\ []) do
    case List.first(Drafts.list_drafts(limit: 1)) do
      nil -> nil
      draft -> render(draft)
    end
  end

  defp render(draft) do
    %TileSpec{
      kind: :latest_draft,
      kind_label: "latest draft",
      composition: :activity,
      title: title(draft),
      body: subtitle(draft),
      art: card_art(draft),
      meta: meta(draft),
      target: {:navigate, "/drafts/#{draft.id}"}
    }
  end

  defp card_art(draft) do
    case p1p1_arena_id(draft.id) do
      nil -> nil
      arena_id -> %{type: :card_image, arena_id: arena_id}
    end
  end

  defp p1p1_arena_id(draft_id) do
    Pick
    |> where([p], p.draft_id == ^draft_id and p.pack_number == 1 and p.pick_number == 1)
    |> select([p], p.picked_arena_id)
    |> Repo.one()
  end

  defp title(draft) do
    set = if is_binary(draft.set_code) and draft.set_code != "", do: draft.set_code, else: nil
    in_progress? = is_nil(draft.completed_at)
    has_record? = (draft.wins || 0) + (draft.losses || 0) > 0

    cond do
      in_progress? and set != nil ->
        "Drafting #{set}"

      in_progress? ->
        "Draft in progress"

      not has_record? and set != nil ->
        "Drafted #{set}"

      not has_record? ->
        "Drafted"

      true ->
        record = format_record(draft.wins, draft.losses)
        if set, do: "#{record} · #{set}", else: record
    end
  end

  defp format_record(nil, nil), do: ""
  defp format_record(nil, l) when is_integer(l), do: "0-#{l}"
  defp format_record(w, nil) when is_integer(w), do: "#{w}-0"
  defp format_record(w, l) when is_integer(w) and is_integer(l), do: "#{w}-#{l}"

  defp subtitle(%{event_name: name}) when is_binary(name) and name != "", do: humanize_event(name)
  defp subtitle(_), do: nil

  defp humanize_event(name) do
    name
    |> String.replace(~r/_\d+$/, "")
    |> String.replace("_", " ")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.trim()
  end

  defp meta(draft) do
    [
      completion_label(draft),
      format_age(draft.completed_at || draft.started_at)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp completion_label(%{wins: 7}), do: "trophy"
  defp completion_label(%{completed_at: nil}), do: "in progress"
  defp completion_label(_), do: nil

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
