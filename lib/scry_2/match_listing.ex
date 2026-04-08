defmodule Scry2.MatchListing do
  @moduledoc """
  Context module for the matches list page projection.

  Owns table: `matches_match_listing`.

  Per ADR-026, this is a page-specific read model separate from
  `Scry2.Matches` (which owns the shared projection tables).
  """

  import Ecto.Query

  alias Scry2.MatchListing.MatchListing
  alias Scry2.Repo

  @doc "Lists matches for a player, newest first."
  def list_matches(opts \\ []) do
    MatchListing
    |> maybe_filter_player(opts[:player_id])
    |> order_by([m], desc: m.started_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  defp maybe_filter_player(query, nil), do: query
  defp maybe_filter_player(query, player_id), do: where(query, [m], m.player_id == ^player_id)

  @doc "Gets a single match listing by ID."
  def get(id), do: Repo.get(MatchListing, id)

  @doc "Gets a match listing by MTGA match ID and player."
  def get_by_mtga_id(mtga_match_id, player_id) do
    Repo.get_by(MatchListing, mtga_match_id: mtga_match_id, player_id: player_id)
  end

  @doc """
  Upserts a match listing by (player_id, mtga_match_id).

  Only replaces the fields present in `attrs` on conflict — does not
  blank out fields set by other event types. This is critical because
  different domain events (MatchCreated, MatchCompleted, GameCompleted,
  DeckSubmitted) each set different columns on the same row.
  """
  def upsert!(attrs) do
    attrs = Map.new(attrs)

    # Only replace fields that are actually being set (excluding the conflict keys).
    replace_fields =
      attrs
      |> Map.drop([:player_id, :mtga_match_id])
      |> Map.keys()

    %MatchListing{}
    |> MatchListing.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace, replace_fields ++ [:updated_at]},
      conflict_target: [:player_id, :mtga_match_id]
    )
  end

  @doc "Count of match listings."
  def count(opts \\ []) do
    MatchListing
    |> maybe_filter_player(opts[:player_id])
    |> Repo.aggregate(:count, :id)
  end
end
