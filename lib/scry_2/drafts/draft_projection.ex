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

  Wins/losses are not stored on draft rows. They are computed at read
  time by `Scry2.Drafts` queries that join `matches_matches` over a
  per-draft time window `[deck_submitted_at, next_deck_submitted_at)`.
  `deck_submitted_at` is stamped when a `DeckSelected` event arrives
  for the draft's `CourseId` (carried as `mtga_draft_id`).

  This replaces the previous design that denormalized wins/losses on
  draft rows and reconciled them from a `matches:updates` PubSub
  subscription. Cross-projection reactive reconciliation was racey
  during parallel rebuild (`replay_projections!`) — DraftProjection
  could finish first and run against an empty `matches_matches`.
  Read-time aggregation removes the denormalization entirely.
  """

  use Scry2.Events.Projector,
    claimed_slugs:
      ~w(draft_started draft_pick_made draft_completed deck_selected human_draft_pack_offered human_draft_pick_made),
    projection_tables: [Scry2.Drafts.Pick, Scry2.Drafts.Draft]

  alias Scry2.Drafts
  alias Scry2.Events.Deck.DeckSelected
  alias Scry2.Events.Draft.{DraftCompleted, DraftPickMade, DraftStarted}
  alias Scry2.Events.Draft.{HumanDraftPackOffered, HumanDraftPickMade}

  if Mix.env() == :test do
    @doc "Test-only helper — calls project/1 directly, bypassing GenServer."
    def project_for_test(event), do: project(event)
  end

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

  # DeckSelected fires when the player submits a deck after drafting. Its
  # `mtga_draft_id` (CourseId from `EventSetDeckV3.request.CourseId`)
  # identifies the draft the deck was submitted from. Stamping
  # `deck_submitted_at` and `mtga_deck_id` on the draft gives read-time
  # aggregation a precise lower bound for "matches played with this deck".
  #
  # Non-draft deck submissions (Constructed, Traditional, etc.) carry no
  # CourseId — those are ignored here.
  defp project(%DeckSelected{mtga_draft_id: course_id} = event)
       when is_binary(course_id) do
    draft = Drafts.get_by_mtga_id(course_id, event.player_id)

    if draft do
      Drafts.upsert_draft!(%{
        mtga_draft_id: course_id,
        player_id: event.player_id,
        deck_submitted_at: event.occurred_at,
        mtga_deck_id: event.deck_id
      })

      Log.info(
        :ingester,
        "projected DeckSelected draft=#{course_id} deck=#{event.deck_id}"
      )
    else
      Log.warning(
        :ingester,
        "DeckSelected for unknown draft #{course_id} — skipping"
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
