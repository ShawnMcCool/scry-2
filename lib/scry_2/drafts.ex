defmodule Scry2.Drafts do
  @moduledoc """
  Context module for draft sessions and individual card picks.

  Owns tables: `drafts_drafts`, `drafts_picks`.

  PubSub role:
    * subscribes to `"mtga_logs:events"` (via `Scry2.Drafts.Ingester`)
    * broadcasts `"drafts:updates"` after any mutation

  Picks reference cards by `arena_id` value, not via a belongs_to — see
  ADR-014 for the cross-context identity invariant.
  """

  import Ecto.Query

  alias Scry2.Drafts.{Draft, Pick}
  alias Scry2.Repo
  alias Scry2.Topics

  @doc "Returns distinct set codes for the player's drafts, most recently played first."
  def list_set_codes(opts \\ []) do
    player_id = Keyword.get(opts, :player_id)

    Draft
    |> maybe_filter_by_player(player_id)
    |> where([d], not is_nil(d.set_code))
    |> order_by([d], desc: d.started_at)
    |> select([d], d.set_code)
    |> distinct(true)
    |> Repo.all()
  end

  @doc "Returns drafts, newest first. Options: :limit, :player_id, :format, :set_code."
  def list_drafts(opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 50)
    player_id = Keyword.get(opts, :player_id)
    format = Keyword.get(opts, :format)
    set_code = Keyword.get(opts, :set_code)

    drafts_with_record_query()
    |> maybe_filter_by_player(player_id)
    |> maybe_filter_by_format(format)
    |> maybe_filter_by_set(set_code)
    |> order_by([d], desc: d.started_at)
    |> limit(^limit_count)
    |> Repo.all()
  end

  @doc """
  Returns aggregate stats for drafts belonging to `player_id`.

  Keys: `:total`, `:win_rate` (float or nil), `:avg_wins` (float or nil),
  `:trophies` (count of 7-win drafts), `:by_format` (list of
  `%{format: string, total: int, win_rate: float}`).

  Wins and losses are computed at read time from `matches_matches` joined
  over each draft's `[deck_submitted_at, next_deck_submitted_at)` window
  (partitioned by `player_id` + `event_name`). Drafts without a
  `deck_submitted_at` contribute zero matches to the totals.
  """
  def draft_stats(opts \\ []) do
    player_id = Keyword.get(opts, :player_id)

    drafts =
      drafts_with_record_query()
      |> maybe_filter_by_player(player_id)
      |> Repo.all()

    total = length(drafts)
    record_drafts = Enum.reject(drafts, fn d -> is_nil(d.wins) and is_nil(d.losses) end)

    total_wins = Enum.sum(Enum.map(record_drafts, &(&1.wins || 0)))
    total_losses = Enum.sum(Enum.map(record_drafts, &(&1.losses || 0)))
    trophies = Enum.count(record_drafts, &((&1.wins || 0) >= 7))

    win_rate =
      if total_wins + total_losses > 0,
        do: total_wins / (total_wins + total_losses),
        else: nil

    avg_wins =
      if Enum.any?(record_drafts),
        do: total_wins / length(record_drafts),
        else: nil

    by_format =
      drafts
      |> Enum.group_by(& &1.format)
      |> Enum.map(fn {format, format_drafts} ->
        played = Enum.reject(format_drafts, fn d -> is_nil(d.wins) and is_nil(d.losses) end)
        w = Enum.sum(Enum.map(played, &(&1.wins || 0)))
        l = Enum.sum(Enum.map(played, &(&1.losses || 0)))
        rate = if w + l > 0, do: w / (w + l), else: nil

        %{
          format: format,
          total: length(format_drafts),
          total_wins: w,
          total_losses: l,
          win_rate: rate
        }
      end)
      |> Enum.sort_by(& &1.total, :desc)

    %{
      total: total,
      win_rate: win_rate,
      avg_wins: avg_wins,
      trophies: trophies,
      by_format: by_format
    }
  end

  # Returns drafts with virtual `:wins` / `:losses` populated by joining
  # `matches_matches` over each draft's
  # `[deck_submitted_at, next_deck_submitted_at)` window, partitioned by
  # `(player_id, event_name)`. Drafts where `deck_submitted_at` is nil
  # get nil wins/losses — there's no window to attribute matches to.
  defp drafts_with_record_query do
    windows_q =
      from d in Draft,
        where: not is_nil(d.deck_submitted_at),
        select: %{
          id: d.id,
          player_id: d.player_id,
          event_name: d.event_name,
          deck_submitted_at: d.deck_submitted_at,
          next_deck_submitted_at:
            fragment(
              "LEAD(?) OVER (PARTITION BY ?, ? ORDER BY ?)",
              d.deck_submitted_at,
              d.player_id,
              d.event_name,
              d.deck_submitted_at
            )
        }

    # `IS` instead of `=` for player_id so nil-player drafts (test fixtures)
    # also match nil-player matches. SQLite treats NULL IS NULL as TRUE,
    # which is what we want — production always has a real player_id, so
    # this collapses to ordinary equality.
    from d in Draft,
      left_join: w in subquery(windows_q),
      on: w.id == d.id,
      left_join: m in "matches_matches",
      on:
        m.event_name == w.event_name and
          fragment("? IS ?", m.player_id, w.player_id) and
          m.started_at >= w.deck_submitted_at and
          (is_nil(w.next_deck_submitted_at) or m.started_at < w.next_deck_submitted_at),
      group_by: d.id,
      select_merge: %{
        wins:
          fragment(
            "CASE WHEN ? IS NULL THEN NULL ELSE CAST(SUM(CASE WHEN ? = 1 THEN 1 ELSE 0 END) AS INTEGER) END",
            d.deck_submitted_at,
            m.won
          ),
        losses:
          fragment(
            "CASE WHEN ? IS NULL THEN NULL ELSE CAST(SUM(CASE WHEN ? = 0 THEN 1 ELSE 0 END) AS INTEGER) END",
            d.deck_submitted_at,
            m.won
          )
      }
  end

  @doc "Returns the draft with its picks preloaded, ordered by pack/pick. Wins/losses are computed at read time."
  def get_draft_with_picks(id) do
    picks_query =
      from p in Pick, order_by: [asc: p.pack_number, asc: p.pick_number]

    drafts_with_record_query()
    |> where([d], d.id == ^id)
    |> Repo.one()
    |> case do
      nil -> nil
      draft -> Repo.preload(draft, picks: picks_query)
    end
  end

  @doc "Returns the draft with the given MTGA id and optional player_id, or nil."
  def get_by_mtga_id(mtga_draft_id, player_id \\ nil) when is_binary(mtga_draft_id) do
    Draft
    |> where([d], d.mtga_draft_id == ^mtga_draft_id)
    |> maybe_filter_by_player(player_id)
    |> Repo.one()
  end

  @doc "Returns the draft with the given event_name and optional player_id, or nil."
  def get_by_event_name(event_name, player_id \\ nil) when is_binary(event_name) do
    Draft
    |> where([d], d.event_name == ^event_name)
    |> maybe_filter_by_player(player_id)
    |> Repo.one()
  end

  @doc """
  Upserts a draft session by `(player_id, mtga_draft_id)`. Idempotent per ADR-016.
  """
  def upsert_draft!(attrs) do
    attrs = Map.new(attrs)
    mtga_id = attrs[:mtga_draft_id]
    player_id = attrs[:player_id]

    draft =
      case get_by_mtga_id(mtga_id, player_id) do
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

  defp find_pick(attrs) do
    draft_id = attrs[:draft_id]
    pack_number = attrs[:pack_number]
    pick_number = attrs[:pick_number]
    Repo.get_by(Pick, draft_id: draft_id, pack_number: pack_number, pick_number: pick_number)
  end

  @doc "Returns the total number of recorded drafts. Optionally filtered by player_id."
  def count(opts \\ []) do
    player_id = Keyword.get(opts, :player_id)

    Draft
    |> maybe_filter_by_player(player_id)
    |> Repo.aggregate(:count)
  end

  defp maybe_filter_by_player(query, nil), do: query
  defp maybe_filter_by_player(query, player_id), do: where(query, [d], d.player_id == ^player_id)

  defp maybe_filter_by_format(query, nil), do: query
  defp maybe_filter_by_format(query, format), do: where(query, [d], d.format == ^format)

  defp maybe_filter_by_set(query, nil), do: query
  defp maybe_filter_by_set(query, set_code), do: where(query, [d], d.set_code == ^set_code)

  defp broadcast_update(draft_id) do
    unless Scry2.Events.SilentMode.silent?() do
      Topics.broadcast(Topics.drafts_updates(), {:draft_updated, draft_id})
    end
  end
end
