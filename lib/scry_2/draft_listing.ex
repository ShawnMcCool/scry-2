defmodule Scry2.DraftListing do
  @moduledoc """
  Context module for draft sessions and individual card picks.

  Owns tables: `drafts_drafts`, `drafts_picks`.

  PubSub role:
    * subscribes to `"mtga_logs:events"` (via `Scry2.DraftListing.Ingester`)
    * broadcasts `"drafts:updates"` after any mutation

  Picks reference cards by `arena_id` value, not via a belongs_to — see
  ADR-014 for the cross-context identity invariant.
  """

  import Ecto.Query

  alias Scry2.DraftListing.{Draft, Pick}
  alias Scry2.Repo
  alias Scry2.Topics

  @doc "Returns the most recent drafts, newest first."
  def list_drafts(opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 50)

    Draft
    |> order_by([d], desc: d.started_at)
    |> limit(^limit_count)
    |> Repo.all()
  end

  @doc "Returns the draft with its picks preloaded, ordered by pack/pick."
  def get_draft_with_picks(id) do
    picks_query =
      from p in Pick, order_by: [asc: p.pack_number, asc: p.pick_number]

    Draft
    |> Repo.get(id)
    |> Repo.preload(picks: picks_query)
  end

  @doc "Returns the draft with the given MTGA id, or nil."
  def get_by_mtga_id(mtga_draft_id) when is_binary(mtga_draft_id) do
    Repo.get_by(Draft, mtga_draft_id: mtga_draft_id)
  end

  @doc """
  Upserts a draft session by `mtga_draft_id`. Idempotent per ADR-016.
  """
  def upsert_draft!(attrs) do
    attrs = Map.new(attrs)
    mtga_id = attrs[:mtga_draft_id] || attrs["mtga_draft_id"]

    draft =
      case get_by_mtga_id(mtga_id) do
        nil -> %Draft{}
        existing -> existing
      end
      |> Draft.changeset(attrs)
      |> Repo.insert_or_update!()

    broadcast_update(draft.id)
    draft
  end

  @doc """
  Upserts a pick by `(draft_id, pack_number, pick_number)`. Idempotent.
  """
  def upsert_pick!(attrs) do
    attrs = Map.new(attrs)

    pick =
      case find_pick(attrs) do
        nil -> %Pick{}
        existing -> existing
      end
      |> Pick.changeset(attrs)
      |> Repo.insert_or_update!()

    broadcast_update(pick.draft_id)
    pick
  end

  defp find_pick(%{draft_id: draft_id, pack_number: p, pick_number: n}) do
    Repo.get_by(Pick, draft_id: draft_id, pack_number: p, pick_number: n)
  end

  @doc "Returns the total number of recorded drafts."
  def count, do: Repo.aggregate(Draft, :count, :id)

  defp broadcast_update(draft_id) do
    Topics.broadcast(Topics.drafts_updates(), {:draft_updated, draft_id})
  end
end
