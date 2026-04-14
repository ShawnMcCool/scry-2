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

  def handle_extra_info({:match_updated, match_id}, state) do
    case Matches.get_match(match_id) do
      nil ->
        {:noreply, state}

      match ->
        update_draft_wins_losses(match.event_name, match.player_id)
        {:noreply, state}
    end
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
        pack_arena_ids: %{"cards" => event.pack_arena_ids || []},
        pool_arena_ids: %{"cards" => []},
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

  defp update_draft_wins_losses(event_name, player_id) do
    case Drafts.get_by_event_name(event_name, player_id) do
      nil ->
        :ok

      draft ->
        matches = Matches.list_matches_for_event(event_name, player_id)
        wins = Enum.count(matches, & &1.won)
        losses = Enum.count(matches, &(not &1.won))

        Drafts.upsert_draft!(%{
          mtga_draft_id: draft.mtga_draft_id,
          player_id: player_id,
          wins: wins,
          losses: losses
        })

        Log.info(
          :ingester,
          "updated wins/losses for draft #{draft.mtga_draft_id}: #{wins}W #{losses}L"
        )
    end
  end

  defp derive_format("QuickDraft_" <> _), do: "quick_draft"
  defp derive_format("PremierDraft_" <> _), do: "premier_draft"
  defp derive_format("TradDraft_" <> _), do: "traditional_draft"
  defp derive_format(_), do: "unknown"

  # Works for event-name-style IDs (e.g. "PremierDraft_FDN_20260401") but returns nil
  # for UUID-style human draft IDs (MTGA's Draft.Notify draftId is a UUID).
  # The UUID case is a known gap — pending real human draft log samples.
  defp extract_set_code(event_name) do
    case String.split(event_name, "_") do
      [_, set | _] -> set
      _ -> nil
    end
  end
end
