defmodule Scry2.Drafts.DraftProjection do
  @moduledoc """
  Pipeline stage 09 — project draft-related domain events into the
  `drafts_*` read models.

  ## Contract

  | | |
  |---|---|
  | **Input**  | `{:domain_event, id, type_slug}` messages on `domain:events` |
  | **Output** | Rows in `drafts_drafts` / `drafts_picks` via `Scry2.Drafts.upsert_*!/1` |
  | **Nature** | GenServer (subscribes at init) |
  | **Called from** | Broadcast from `Scry2.Events.append!/2` |
  | **Calls** | `Scry2.Events.get!/1` → `Scry2.Drafts.upsert_draft!/1` / `upsert_pick!/1` |

  Also subscribes to `matches:updates` to keep draft wins/losses in sync
  whenever a match for the same event_name is recorded or updated.
  """

  # projection_tables listed in FK-safe delete order (children first)
  use Scry2.Events.Projector,
    claimed_slugs:
      ~w(draft_started draft_pick_made draft_completed human_draft_pack_offered human_draft_pick_made),
    projection_tables: [Scry2.Drafts.Pick, Scry2.Drafts.Draft]

  alias Scry2.Drafts
  alias Scry2.Events.Draft.{DraftCompleted, DraftPickMade, DraftStarted}
  alias Scry2.Events.Draft.{HumanDraftPackOffered, HumanDraftPickMade}
  alias Scry2.Matches
  alias Scry2.Repo
  alias Scry2.Topics

  if Mix.env() == :test do
    @doc "Test-only helper — calls project/1 directly, bypassing GenServer."
    def project_for_test(event), do: project(event)

    @doc "Test-only helper — calls handle_extra_info/2 directly."
    def handle_extra_info_for_test(msg, state), do: handle_extra_info(msg, state)
  end

  def after_init(_opts) do
    Topics.subscribe(Topics.matches_updates())
  end

  @doc """
  Reconciles every draft's `wins` / `losses` from `matches_matches`
  using a per-draft time window so multiple drafts that share the
  same MTGA `event_name` (`PremierDraft_SOS_20260421`,
  `PickTwoDraft_SOS_20260421`, etc.) don't collide.

  The window for a draft is `[draft.started_at, next_draft.started_at)`
  where `next_draft` is the next draft of the same `event_name` and
  `player_id` ordered by `started_at`. Quick Draft is unaffected by
  this — its `mtga_draft_id` is the event-name string, so each Quick
  Draft already has a unique event_name and its window naturally
  collapses onto its own matches.

  Single SQL with a CTE — runs in milliseconds even on full history.
  Used both at the end of a rebuild (no broadcast cascade fires
  thanks to `Scry2.Events.SilentMode`) and on every live
  `:match_updated` (see `handle_extra_info/2`) — the query is cheap
  enough that doing the full reconciliation for one match-update is
  simpler and more correct than trying to surgically update one
  draft.
  """
  def post_rebuild do
    Repo.query!("""
    WITH windows AS (
      SELECT
        d.id AS draft_id,
        d.event_name,
        d.player_id,
        d.started_at,
        LEAD(d.started_at) OVER (
          PARTITION BY d.event_name, d.player_id
          ORDER BY d.started_at
        ) AS next_started_at
      FROM drafts_drafts d
    ),
    counts AS (
      SELECT
        w.draft_id,
        COALESCE(SUM(CASE WHEN m.won = 1 THEN 1 ELSE 0 END), 0) AS wins,
        COALESCE(SUM(CASE WHEN m.won = 0 THEN 1 ELSE 0 END), 0) AS losses
      FROM windows w
      LEFT JOIN matches_matches m
        ON m.event_name = w.event_name
       AND m.player_id  = w.player_id
       AND m.started_at >= w.started_at
       AND (w.next_started_at IS NULL OR m.started_at < w.next_started_at)
      GROUP BY w.draft_id
    )
    UPDATE drafts_drafts
    SET
      wins   = COALESCE((SELECT wins   FROM counts WHERE counts.draft_id = drafts_drafts.id), 0),
      losses = COALESCE((SELECT losses FROM counts WHERE counts.draft_id = drafts_drafts.id), 0),
      updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
    """)

    :ok
  end

  def handle_extra_info({:match_updated, match_id}, state) do
    case Matches.get_match(match_id) do
      nil ->
        {:noreply, state}

      _match ->
        # The single-event_name recount we used to do here was wrong for
        # human drafts (Premier, Pick Two, Trad), which use a shared
        # event_name across many drafts of the same format/set/date and
        # only differentiate via the per-event mtga_draft_id. Calling the
        # full time-window reconciliation in `post_rebuild/0` is one fast
        # SQL statement and is correct in every case.
        post_rebuild()
        {:noreply, state}
    end
  end

  def handle_extra_info(_msg, state), do: {:noreply, state}

  defp project(%DraftStarted{} = event) do
    attrs = %{
      player_id: event.player_id,
      mtga_draft_id: event.mtga_draft_id,
      event_name: event.event_name,
      format: derive_format(event.event_name),
      set_code: event.set_code,
      started_at: event.occurred_at
    }

    draft = Drafts.upsert_draft!(attrs)

    Log.info(
      :ingester,
      "projected DraftStarted mtga_draft_id=#{draft.mtga_draft_id} set=#{event.set_code}"
    )

    :ok
  end

  defp project(%DraftPickMade{} = event) do
    draft = Drafts.get_by_mtga_id(event.mtga_draft_id, event.player_id)

    if draft do
      attrs = %{
        draft_id: draft.id,
        pack_number: event.pack_number,
        pick_number: event.pick_number,
        picked_arena_id: event.picked_arena_id,
        auto_pick: event.auto_pick,
        time_remaining: event.time_remaining,
        picked_at: event.occurred_at
      }

      pick = Drafts.upsert_pick!(attrs)

      Log.info(
        :ingester,
        "projected DraftPickMade draft=#{event.mtga_draft_id} p#{pick.pack_number}p#{pick.pick_number}"
      )
    else
      Log.warning(
        :ingester,
        "DraftPickMade for unknown draft #{event.mtga_draft_id} — skipping projection"
      )
    end

    :ok
  end

  defp project(%DraftCompleted{} = event) do
    draft = Drafts.get_by_mtga_id(event.mtga_draft_id, event.player_id)

    if draft do
      Drafts.upsert_draft!(%{
        mtga_draft_id: event.mtga_draft_id,
        player_id: event.player_id,
        card_pool_arena_ids: %{"ids" => event.card_pool_arena_ids || []},
        completed_at: event.occurred_at
      })

      Log.info(:ingester, "projected DraftCompleted mtga_draft_id=#{event.mtga_draft_id}")
    else
      Log.warning(
        :ingester,
        "DraftCompleted for unknown draft #{event.mtga_draft_id} — skipping"
      )
    end

    :ok
  end

  defp project(%HumanDraftPackOffered{} = event) do
    draft = ensure_human_draft!(event)

    attrs = %{
      draft_id: draft.id,
      pack_number: event.pack_number,
      pick_number: event.pick_number,
      pack_arena_ids: %{"cards" => event.pack_arena_ids || []},
      picked_at: event.occurred_at
    }

    Drafts.upsert_pick!(attrs)

    Log.info(
      :ingester,
      "projected HumanDraftPackOffered draft=#{event.mtga_draft_id} p#{event.pack_number}p#{event.pick_number}"
    )

    :ok
  end

  defp project(%HumanDraftPickMade{} = event) do
    draft = Drafts.get_by_mtga_id(event.mtga_draft_id, event.player_id)

    if draft do
      picked = List.first(event.picked_arena_ids || [])

      attrs = %{
        draft_id: draft.id,
        pack_number: event.pack_number,
        pick_number: event.pick_number,
        picked_arena_id: picked,
        picked_arena_ids: %{"ids" => event.picked_arena_ids || []},
        picked_at: event.occurred_at
      }

      Drafts.upsert_pick!(attrs)

      Log.info(
        :ingester,
        "projected HumanDraftPickMade draft=#{event.mtga_draft_id} p#{event.pack_number}p#{event.pick_number}"
      )
    else
      Log.warning(
        :ingester,
        "HumanDraftPickMade for unknown draft #{event.mtga_draft_id} — skipping"
      )
    end

    :ok
  end

  # Catch-all: ignore event types not handled above (guards against FunctionClauseError
  # if new event slugs are claimed before their project/1 clause is added).
  defp project(_event), do: :ok

  # Human drafts have no DraftStarted event. Create the draft row on the
  # first HumanDraftPackOffered if it doesn't exist yet.
  #
  # event_name is set to mtga_draft_id. For event-name-style IDs
  # (e.g. "PremierDraft_FDN_20260401") this matches what MTGA uses in match
  # and ranking events, so match linkage works. For UUID-style draft IDs (seen
  # in Draft.Notify payloads), MTGA is expected to use the same UUID as the
  # event_name in subsequent match events — unverified against real log samples.
  defp ensure_human_draft!(event) do
    case Drafts.get_by_mtga_id(event.mtga_draft_id, event.player_id) do
      nil ->
        set_code = extract_set_code(event.mtga_draft_id)

        Drafts.upsert_draft!(%{
          player_id: event.player_id,
          mtga_draft_id: event.mtga_draft_id,
          event_name: event.mtga_draft_id,
          format: derive_format(event.mtga_draft_id),
          set_code: set_code,
          started_at: event.occurred_at
        })

      existing ->
        existing
    end
  end

  # Parses any MTGA InternalEventName of the form
  # `<TypeName>Draft_<SET>_<YYYYMMDD>` into a format slug. Delegates to
  # the anti-corruption layer's parser so the format vocabulary stays
  # consistent across the pipeline.
  defp derive_format(event_name) do
    case Scry2.Events.IdentifyDomainEvents.parse_draft_event_name(event_name) do
      {format, _set} -> format
      _ -> "unknown"
    end
  end

  defp extract_set_code(event_name) do
    case Scry2.Events.IdentifyDomainEvents.parse_draft_event_name(event_name) do
      {_format, set} -> set
      _ -> nil
    end
  end
end
