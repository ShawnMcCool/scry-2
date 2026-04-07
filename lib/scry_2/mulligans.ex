defmodule Scry2.Mulligans do
  @moduledoc """
  Context module for mulligan data — read-optimized projections
  for the mulligans page.

  Owns table: `mulligans_mulligan_listing`.

  PubSub role: broadcasts `"mulligans:updates"` after projection writes.

  This context exists per ADR-026 (page-specific projections). The
  mulligans page queries this context directly rather than assembling
  data from the event log and matches table at render time.
  """

  import Ecto.Query

  alias Scry2.Mulligans.MulliganListing
  alias Scry2.Repo

  @doc """
  Lists all mulligan hands for the given player, ordered by
  `occurred_at` descending (newest first).
  """
  def list_hands(opts \\ []) do
    MulliganListing
    |> maybe_filter_player(opts[:player_id])
    |> order_by([m], desc: m.occurred_at)
    |> Repo.all()
  end

  defp maybe_filter_player(query, nil), do: query
  defp maybe_filter_player(query, player_id), do: where(query, [m], m.player_id == ^player_id)

  @doc """
  Upserts a mulligan listing row by `(mtga_match_id, occurred_at)`.
  """
  def upsert_hand!(attrs) do
    attrs = Map.new(attrs)

    %MulliganListing{}
    |> MulliganListing.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:mtga_match_id, :occurred_at]
    )
  end

  @doc """
  Stamps `event_name` on all mulligan rows for a given match.
  Called when `MatchCreated` is projected (which carries the event name).
  """
  def stamp_event_name!(mtga_match_id, event_name)
      when is_binary(mtga_match_id) and is_binary(event_name) do
    from(m in MulliganListing, where: m.mtga_match_id == ^mtga_match_id)
    |> Repo.update_all(set: [event_name: event_name])
  end
end
