defmodule Scry2.Matches do
  @moduledoc """
  Context module for recorded matches, games, and deck submissions.

  Owns tables: `matches_matches`, `matches_games`, `matches_deck_submissions`.

  PubSub role:
    * subscribes to `"mtga_logs:events"` (via `Scry2.Matches.Ingester`)
    * broadcasts `"matches:updates"` after any mutation

  All upserts target MTGA-provided ids (`mtga_match_id`, `mtga_deck_id`)
  for idempotency — see ADR-016.
  """

  import Ecto.Query

  alias Scry2.Matches.{DeckSubmission, Game, Match}
  alias Scry2.Repo
  alias Scry2.Topics

  @doc "Returns the most recent matches, newest first."
  def list_matches(opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 50)

    Match
    |> order_by([m], desc: m.started_at)
    |> limit(^limit_count)
    |> Repo.all()
  end

  @doc "Returns the match with its games and deck submissions preloaded."
  def get_match_with_associations(id) do
    Match
    |> Repo.get(id)
    |> Repo.preload([:games, :deck_submissions])
  end

  @doc "Returns the match with the given MTGA id, or nil."
  def get_by_mtga_id(mtga_match_id) when is_binary(mtga_match_id) do
    Repo.get_by(Match, mtga_match_id: mtga_match_id)
  end

  @doc """
  Inserts a new match or updates the existing one with the same
  `mtga_match_id`. Idempotent per ADR-016.
  """
  def upsert_match!(attrs) do
    attrs = Map.new(attrs)
    mtga_id = attrs[:mtga_match_id] || attrs["mtga_match_id"]

    match =
      case get_by_mtga_id(mtga_id) do
        nil -> %Match{}
        existing -> existing
      end
      |> Match.changeset(attrs)
      |> Repo.insert_or_update!()

    broadcast_update(match.id)
    match
  end

  @doc "Inserts a single game under a match."
  def insert_game!(attrs) do
    game =
      %Game{}
      |> Game.changeset(Map.new(attrs))
      |> Repo.insert!()

    broadcast_update(game.match_id)
    game
  end

  @doc """
  Upserts a deck submission by `mtga_deck_id`. Idempotent per ADR-016.
  """
  def upsert_deck_submission!(attrs) do
    attrs = Map.new(attrs)
    mtga_id = attrs[:mtga_deck_id] || attrs["mtga_deck_id"]

    submission =
      case Repo.get_by(DeckSubmission, mtga_deck_id: mtga_id) do
        nil -> %DeckSubmission{}
        existing -> existing
      end
      |> DeckSubmission.changeset(attrs)
      |> Repo.insert_or_update!()

    if submission.match_id, do: broadcast_update(submission.match_id)
    submission
  end

  @doc "Returns the total number of recorded matches."
  def count, do: Repo.aggregate(Match, :count, :id)

  defp broadcast_update(match_id) do
    Topics.broadcast(Topics.matches_updates(), {:match_updated, match_id})
  end
end
