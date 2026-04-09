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

  ## Status

  `@claimed_slugs` is empty — the translator does not yet produce any
  draft domain events because the user's Player.log contains no draft
  activity. This module exists as a structural placeholder matching
  `Scry2.Matches.MatchProjection`, so that once draft fixtures exist and the
  translator learns `%DraftStarted{}` / `%DraftPickMade{}`, the projector
  pattern is already in place.

  See `TODO.md` > "Match ingestion follow-ups" > Drafts.
  """
  # projection_tables listed in FK-safe delete order (children first)
  use Scry2.Events.Projector,
    claimed_slugs: ~w(draft_started draft_pick_made),
    projection_tables: [Scry2.Drafts.Pick, Scry2.Drafts.Draft]

  alias Scry2.Drafts
  alias Scry2.Events.Draft.{DraftPickMade, DraftStarted}

  defp project(%DraftStarted{} = event) do
    attrs = %{
      player_id: event.player_id,
      mtga_draft_id: event.mtga_draft_id,
      event_name: event.event_name,
      format: "quick_draft",
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
end
