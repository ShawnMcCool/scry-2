# Drafts Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the drafts projection (all five event types, cross-context wins/losses), and rebuild the DraftsLive UI with a stats dashboard, format/set filters, and a three-tab detail view (Picks with full pack images · Deck with type-grouped pool · Matches with deck links).

**Architecture:** Extend the Projector macro with overridable hooks so DraftProjection can subscribe to `matches:updates` and stamp wins/losses from incoming match broadcasts. Migrations add `card_pool_arena_ids` to drafts and `auto_pick`/`time_remaining`/`picked_arena_ids` to picks. The LiveView follows established matches/decks patterns: stat cards + format breakdown on list, tabbed detail loaded lazily per-tab.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, SQLite, Tailwind 4 + daisyUI, `<.card_image>` component.

---

## File Map

| File | Action |
|---|---|
| `priv/repo/migrations/TIMESTAMP_add_card_pool_to_drafts_drafts.exs` | Create |
| `priv/repo/migrations/TIMESTAMP_add_fields_to_drafts_picks.exs` | Create |
| `lib/scry_2/drafts/draft.ex` | Modify — add `card_pool_arena_ids` field |
| `lib/scry_2/drafts/pick.ex` | Modify — add `auto_pick`, `time_remaining`, `picked_arena_ids`; make `picked_arena_id` optional |
| `lib/scry_2/events/projector.ex` | Modify — add `defoverridable` hooks for `init/1` and `handle_extra_info/2` |
| `lib/scry_2/matches.ex` | Modify — add `get_match/1`, `list_matches_for_event/2`, `list_decks_for_event/2` |
| `lib/scry_2/drafts.ex` | Modify — add `draft_stats/1`, extend `list_drafts` with format/set filters |
| `lib/scry_2/drafts/draft_projection.ex` | Modify — complete all five event handlers, wins/losses PubSub listener |
| `lib/scry_2_web/live/drafts_helpers.ex` | Modify — add stats helpers, trophy detection, pool grouping, win rate |
| `lib/scry_2_web/live/drafts_live.ex` | Rewrite — full list + three-tab detail view |
| `test/scry_2/matches_test.exs` | Modify — new function tests |
| `test/scry_2/drafts_test.exs` | Modify — new function tests |
| `test/scry_2/drafts/draft_projection_test.exs` | Modify/Create — all five handler tests + wins/losses |
| `test/scry_2_web/live/drafts_live_test.exs` | Modify/Create — list view + tab navigation |
| `test/support/factory.ex` | Modify — add `build_human_draft_pack_offered` factory |

---

## Task 1: Migrations

**Files:**
- Create: `priv/repo/migrations/TIMESTAMP_add_card_pool_to_drafts_drafts.exs`
- Create: `priv/repo/migrations/TIMESTAMP_add_fields_to_drafts_picks.exs`

- [ ] **Step 1: Generate the first migration**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix ecto.gen.migration add_card_pool_to_drafts_drafts
```

- [ ] **Step 2: Write the first migration body**

Open the generated file and replace the `change/0` body:

```elixir
def change do
  alter table(:drafts_drafts) do
    add :card_pool_arena_ids, :map
  end
end
```

- [ ] **Step 3: Generate the second migration**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix ecto.gen.migration add_fields_to_drafts_picks
```

- [ ] **Step 4: Write the second migration body**

```elixir
def change do
  alter table(:drafts_picks) do
    add :auto_pick, :boolean
    add :time_remaining, :float
    add :picked_arena_ids, :map
  end
end
```

- [ ] **Step 5: Run migrations**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix ecto.migrate
```

Expected: Both migrations run, no errors.

- [ ] **Step 6: Commit**

```bash
jj desc -m "feat: add card_pool_arena_ids to drafts, add auto_pick/time_remaining/picked_arena_ids to picks"
jj new
```

---

## Task 2: Schema Updates

**Files:**
- Modify: `lib/scry_2/drafts/draft.ex`
- Modify: `lib/scry_2/drafts/pick.ex`

- [ ] **Step 1: Update `Draft` schema**

In `lib/scry_2/drafts/draft.ex`, add `card_pool_arena_ids` to the schema and changeset:

```elixir
schema "drafts_drafts" do
  field :player_id, :integer
  field :mtga_draft_id, :string
  field :event_name, :string
  field :format, :string
  field :set_code, :string
  field :started_at, :utc_datetime
  field :completed_at, :utc_datetime
  field :wins, :integer
  field :losses, :integer
  field :card_pool_arena_ids, :map

  has_many :picks, Scry2.Drafts.Pick

  timestamps(type: :utc_datetime)
end

def changeset(draft, attrs) do
  draft
  |> cast(attrs, [
    :player_id,
    :mtga_draft_id,
    :event_name,
    :format,
    :set_code,
    :started_at,
    :completed_at,
    :wins,
    :losses,
    :card_pool_arena_ids
  ])
  |> validate_required([:mtga_draft_id])
  |> unique_constraint([:player_id, :mtga_draft_id])
end
```

- [ ] **Step 2: Update `Pick` schema**

In `lib/scry_2/drafts/pick.ex`, add the three new fields and make `picked_arena_id` optional (human drafts create picks with pack contents before the pick is made):

```elixir
schema "drafts_picks" do
  field :pack_number, :integer
  field :pick_number, :integer
  # References Scry2.Cards.Card.arena_id by value — cross-context per
  # ADR-014. Never a belongs_to.
  field :picked_arena_id, :integer
  field :pack_arena_ids, :map
  field :pool_arena_ids, :map
  field :picked_at, :utc_datetime
  field :auto_pick, :boolean
  field :time_remaining, :float
  # List of arena_ids; multi-element for Pick Two format, single-element
  # for standard picks. Stored as %{"ids" => [integer]}.
  field :picked_arena_ids, :map

  belongs_to :draft, Scry2.Drafts.Draft

  timestamps(type: :utc_datetime)
end

def changeset(pick, attrs) do
  pick
  |> cast(attrs, [
    :draft_id,
    :pack_number,
    :pick_number,
    :picked_arena_id,
    :pack_arena_ids,
    :pool_arena_ids,
    :picked_at,
    :auto_pick,
    :time_remaining,
    :picked_arena_ids
  ])
  |> validate_required([:draft_id, :pack_number, :pick_number])
  |> unique_constraint([:draft_id, :pack_number, :pick_number],
    name: :drafts_picks_draft_id_pack_number_pick_number_index
  )
end
```

- [ ] **Step 3: Verify compile**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warning-as-errors 2>&1 | head -30
```

Expected: No warnings, no errors.

- [ ] **Step 4: Commit**

```bash
jj desc -m "feat: update Draft and Pick schemas with new fields"
jj new
```

---

## Task 3: Projector Macro — Overridable Hooks

**Files:**
- Modify: `lib/scry_2/events/projector.ex`

The Projector macro defines `init/1` and a `handle_info(_other, state)` catch-all. To allow `DraftProjection` to subscribe to extra topics and handle their messages without ordering conflicts, add two overridable hooks.

- [ ] **Step 1: Add `after_init/1` hook to the macro**

In `lib/scry_2/events/projector.ex`, inside the `quote do` block, change `init/1` to call `after_init/1` and mark it overridable. Find the existing `def init(_opts)` block and replace it:

```elixir
@impl true
def init(_opts) do
  Topics.subscribe(Topics.domain_events())
  Topics.subscribe(Topics.domain_control())
  after_init(_opts)
  {:ok, %{}}
end

def after_init(_opts), do: :ok
```

- [ ] **Step 2: Add `handle_extra_info/2` hook**

Find the catch-all at the end of the quote block:
```elixir
def handle_info(_other, state), do: {:noreply, state}
```

Replace it with:
```elixir
def handle_info(msg, state), do: handle_extra_info(msg, state)
def handle_extra_info(_msg, state), do: {:noreply, state}
```

- [ ] **Step 3: Mark both hooks as overridable**

After the two new `def` lines (still inside `quote do`), add:

```elixir
defoverridable after_init: 1, handle_extra_info: 2
```

- [ ] **Step 4: Verify all existing projectors still compile**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warning-as-errors 2>&1 | head -30
```

Expected: No warnings. All projectors that use the macro (MatchProjection, DraftProjection, etc.) still compile cleanly since the new hooks have default implementations.

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: add overridable after_init and handle_extra_info hooks to Projector macro"
jj new
```

---

## Task 4: Matches Context — New Public Functions

**Files:**
- Modify: `lib/scry_2/matches.ex`
- Modify: `test/scry_2/matches_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/scry_2/matches_test.exs`:

```elixir
describe "get_match/1" do
  test "returns match by id" do
    match = create_match(%{event_name: "QuickDraft_FDN_20260401"})
    assert Matches.get_match(match.id).id == match.id
  end

  test "returns nil for unknown id" do
    assert Matches.get_match(999_999) == nil
  end
end

describe "list_matches_for_event/2" do
  test "returns matches for the given event_name and player_id" do
    player_id = 42
    match = create_match(%{event_name: "QuickDraft_FDN_20260401", player_id: player_id, won: true})
    _other = create_match(%{event_name: "OtherEvent_FDN_20260401", player_id: player_id})

    results = Matches.list_matches_for_event("QuickDraft_FDN_20260401", player_id)
    assert length(results) == 1
    assert hd(results).id == match.id
  end

  test "returns empty list when no matches" do
    assert Matches.list_matches_for_event("NoSuchEvent", 1) == []
  end
end

describe "list_decks_for_event/2" do
  test "returns distinct deck entries used in the event" do
    player_id = 42
    create_match(%{
      event_name: "QuickDraft_FDN_20260401",
      player_id: player_id,
      mtga_deck_id: "deck-abc",
      deck_name: "UR Control"
    })
    # Duplicate deck_id — should only appear once
    create_match(%{
      event_name: "QuickDraft_FDN_20260401",
      player_id: player_id,
      mtga_deck_id: "deck-abc",
      deck_name: "UR Control"
    })

    results = Matches.list_decks_for_event("QuickDraft_FDN_20260401", player_id)
    assert length(results) == 1
    assert hd(results).mtga_deck_id == "deck-abc"
    assert hd(results).deck_name == "UR Control"
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/matches_test.exs 2>&1 | tail -20
```

Expected: Failures with "undefined function Matches.get_match/1" etc.

- [ ] **Step 3: Implement the three functions in `lib/scry_2/matches.ex`**

Add after the existing `list_matches_in_range/2`:

```elixir
@doc "Returns a single match by id, or nil."
def get_match(id), do: Repo.get(Match, id)

@doc "Returns all matches for a given event_name and player, newest first."
def list_matches_for_event(event_name, player_id) do
  Match
  |> where([m], m.event_name == ^event_name and m.player_id == ^player_id)
  |> order_by([m], desc: m.started_at)
  |> Repo.all()
end

@doc """
Returns distinct deck entries (mtga_deck_id, deck_name, deck_colors) used
in matches for the given event_name and player. One entry per unique mtga_deck_id.
"""
def list_decks_for_event(event_name, player_id) do
  Match
  |> where([m], m.event_name == ^event_name and m.player_id == ^player_id)
  |> where([m], not is_nil(m.mtga_deck_id))
  |> select([m], %{
    mtga_deck_id: m.mtga_deck_id,
    deck_name: m.deck_name,
    deck_colors: m.deck_colors
  })
  |> distinct([m], m.mtga_deck_id)
  |> order_by([m], desc: m.started_at)
  |> Repo.all()
end
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/matches_test.exs 2>&1 | tail -10
```

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: add get_match, list_matches_for_event, list_decks_for_event to Matches context"
jj new
```

---

## Task 5: Drafts Context — Stats and Filters

**Files:**
- Modify: `lib/scry_2/drafts.ex`
- Modify: `test/scry_2/drafts_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/scry_2/drafts_test.exs`:

```elixir
describe "draft_stats/1" do
  test "returns zeros when no drafts" do
    stats = Drafts.draft_stats(player_id: 99)
    assert stats.total == 0
    assert stats.win_rate == nil
    assert stats.avg_wins == nil
    assert stats.trophies == 0
    assert stats.by_format == []
  end

  test "computes total, win_rate, avg_wins, trophies" do
    player_id = 1
    create_draft(%{player_id: player_id, wins: 7, losses: 0, completed_at: DateTime.utc_now(:second), format: "quick_draft"})
    create_draft(%{player_id: player_id, wins: 3, losses: 3, completed_at: DateTime.utc_now(:second), format: "quick_draft"})
    create_draft(%{player_id: player_id, wins: nil, losses: nil, completed_at: nil, format: "quick_draft"})

    stats = Drafts.draft_stats(player_id: player_id)
    assert stats.total == 3
    assert stats.trophies == 1
    assert_in_delta stats.win_rate, 0.625, 0.01  # 10/(10+6)
    assert_in_delta stats.avg_wins, 5.0, 0.01    # (7+3)/2 complete drafts
  end

  test "by_format breakdown" do
    player_id = 2
    create_draft(%{player_id: player_id, wins: 6, losses: 1, completed_at: DateTime.utc_now(:second), format: "quick_draft"})
    create_draft(%{player_id: player_id, wins: 2, losses: 3, completed_at: DateTime.utc_now(:second), format: "premier_draft"})

    stats = Drafts.draft_stats(player_id: player_id)
    qd = Enum.find(stats.by_format, &(&1.format == "quick_draft"))
    pd = Enum.find(stats.by_format, &(&1.format == "premier_draft"))

    assert qd.total == 1
    assert_in_delta qd.win_rate, 0.857, 0.01
    assert pd.total == 1
    assert_in_delta pd.win_rate, 0.4, 0.01
  end
end

describe "list_drafts/1 with filters" do
  test "filters by format" do
    player_id = 3
    _qd = create_draft(%{player_id: player_id, format: "quick_draft"})
    pd = create_draft(%{player_id: player_id, format: "premier_draft"})

    results = Drafts.list_drafts(player_id: player_id, format: "premier_draft")
    assert length(results) == 1
    assert hd(results).id == pd.id
  end

  test "filters by set_code" do
    player_id = 4
    fdn = create_draft(%{player_id: player_id, set_code: "FDN"})
    _blb = create_draft(%{player_id: player_id, set_code: "BLB"})

    results = Drafts.list_drafts(player_id: player_id, set_code: "FDN")
    assert length(results) == 1
    assert hd(results).id == fdn.id
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/drafts_test.exs 2>&1 | tail -20
```

- [ ] **Step 3: Implement `draft_stats/1`**

Add to `lib/scry_2/drafts.ex`:

```elixir
@doc """
Returns aggregate stats for drafts belonging to `player_id`.

Keys: `:total`, `:win_rate` (float or nil), `:avg_wins` (float or nil),
`:trophies` (count of 7-win drafts), `:by_format` (list of
`%{format: string, total: int, win_rate: float}`).

Only complete drafts (completed_at not nil) contribute to rates and averages.
"""
def draft_stats(opts \\ []) do
  player_id = Keyword.get(opts, :player_id)

  base =
    Draft
    |> maybe_filter_by_player(player_id)

  total = Repo.aggregate(base, :count)

  complete_base = where(base, [d], not is_nil(d.completed_at))

  {total_wins, total_losses, trophies} =
    complete_base
    |> select([d], {
      sum(d.wins),
      sum(d.losses),
      count(d.id, :distinct) |> filter(d.wins == 7)
    })
    |> Repo.one()
    |> then(fn {w, l, t} -> {w || 0, l || 0, t || 0} end)

  win_rate =
    if total_wins + total_losses > 0,
      do: total_wins / (total_wins + total_losses),
      else: nil

  complete_count = Repo.aggregate(complete_base, :count)

  avg_wins =
    if complete_count > 0,
      do: total_wins / complete_count,
      else: nil

  by_format =
    complete_base
    |> group_by([d], d.format)
    |> select([d], %{
      format: d.format,
      total: count(d.id),
      total_wins: sum(d.wins),
      total_losses: sum(d.losses)
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      w = row.total_wins || 0
      l = row.total_losses || 0
      rate = if w + l > 0, do: w / (w + l), else: nil
      Map.merge(row, %{win_rate: rate})
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
```

- [ ] **Step 4: Extend `list_drafts/1` with format and set_code filters**

Replace the existing `list_drafts/1`:

```elixir
@doc "Returns drafts, newest first. Options: :limit, :player_id, :format, :set_code."
def list_drafts(opts \\ []) do
  limit_count = Keyword.get(opts, :limit, 50)
  player_id = Keyword.get(opts, :player_id)
  format = Keyword.get(opts, :format)
  set_code = Keyword.get(opts, :set_code)

  Draft
  |> maybe_filter_by_player(player_id)
  |> maybe_filter_by_format(format)
  |> maybe_filter_by_set(set_code)
  |> order_by([d], desc: d.started_at)
  |> limit(^limit_count)
  |> Repo.all()
end

defp maybe_filter_by_format(query, nil), do: query
defp maybe_filter_by_format(query, format), do: where(query, [d], d.format == ^format)

defp maybe_filter_by_set(query, nil), do: query
defp maybe_filter_by_set(query, set_code), do: where(query, [d], d.set_code == ^set_code)
```

- [ ] **Step 5: Run tests**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/drafts_test.exs 2>&1 | tail -10
```

Expected: All pass.

- [ ] **Step 6: Commit**

```bash
jj desc -m "feat: add draft_stats and format/set filters to Drafts context"
jj new
```

---

## Task 6: DraftProjection — Format Derivation + DraftCompleted

**Files:**
- Modify: `lib/scry_2/drafts/draft_projection.ex`
- Modify: `test/scry_2/drafts/draft_projection_test.exs` (create if absent)

- [ ] **Step 1: Write failing tests**

In `test/scry_2/drafts/draft_projection_test.exs`:

```elixir
defmodule Scry2.Drafts.DraftProjectionTest do
  use Scry2.DataCase, async: false

  alias Scry2.Drafts
  alias Scry2.TestFactory, as: Factory

  describe "DraftStarted — format derivation" do
    test "derives quick_draft from QuickDraft_ event name" do
      event = Factory.build_draft_started(%{
        event_name: "QuickDraft_FDN_20260401",
        mtga_draft_id: "QuickDraft_FDN_20260401"
      })

      Scry2.Drafts.DraftProjection.project_for_test(event)

      draft = Drafts.get_by_mtga_id("QuickDraft_FDN_20260401")
      assert draft.format == "quick_draft"
    end

    test "derives premier_draft from PremierDraft_ event name" do
      event = Factory.build_draft_started(%{
        event_name: "PremierDraft_FDN_20260401",
        mtga_draft_id: "PremierDraft_FDN_20260401"
      })

      Scry2.Drafts.DraftProjection.project_for_test(event)

      draft = Drafts.get_by_mtga_id("PremierDraft_FDN_20260401")
      assert draft.format == "premier_draft"
    end

    test "derives traditional_draft from TradDraft_ event name" do
      event = Factory.build_draft_started(%{
        event_name: "TradDraft_FDN_20260401",
        mtga_draft_id: "TradDraft_FDN_20260401"
      })

      Scry2.Drafts.DraftProjection.project_for_test(event)

      draft = Drafts.get_by_mtga_id("TradDraft_FDN_20260401")
      assert draft.format == "traditional_draft"
    end
  end

  describe "DraftCompleted" do
    test "sets card_pool_arena_ids and completed_at on the draft" do
      draft = Factory.create_draft(%{mtga_draft_id: "QuickDraft_FDN_20260401"})
      pool = [11111, 22222, 33333]

      event = Factory.build_draft_completed(%{
        mtga_draft_id: "QuickDraft_FDN_20260401",
        player_id: draft.player_id,
        card_pool_arena_ids: pool,
        is_bot_draft: true,
        occurred_at: DateTime.utc_now(:second)
      })

      Scry2.Drafts.DraftProjection.project_for_test(event)

      updated = Drafts.get_by_mtga_id("QuickDraft_FDN_20260401")
      assert updated.card_pool_arena_ids == %{"ids" => pool}
      assert updated.completed_at != nil
    end

    test "is a no-op when draft row does not exist" do
      event = Factory.build_draft_completed(%{
        mtga_draft_id: "UnknownDraft_FDN_20260401",
        player_id: nil,
        card_pool_arena_ids: [1, 2, 3]
      })

      assert Scry2.Drafts.DraftProjection.project_for_test(event) == :ok
    end
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/drafts/draft_projection_test.exs 2>&1 | tail -20
```

- [ ] **Step 3: Add `project_for_test/1` and fix format derivation**

Replace `lib/scry_2/drafts/draft_projection.ex` with:

```elixir
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

  Also subscribes to `matches:updates` to keep `wins`/`losses` current as
  matches for draft events are recorded.
  """

  use Scry2.Events.Projector,
    claimed_slugs: ~w(draft_started draft_pick_made draft_completed human_draft_pack_offered human_draft_pick_made),
    projection_tables: [Scry2.Drafts.Pick, Scry2.Drafts.Draft]

  alias Scry2.Drafts
  alias Scry2.Matches
  alias Scry2.Topics
  alias Scry2.Events.Draft.{
    DraftCompleted,
    DraftPickMade,
    DraftStarted,
    HumanDraftPackOffered,
    HumanDraftPickMade
  }

  # Expose project/1 for tests only.
  if Mix.env() == :test do
    def project_for_test(event), do: project(event)
  end

  @impl true
  def after_init(_opts) do
    Topics.subscribe(Topics.matches_updates())
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
        picked_arena_ids: %{"ids" => [event.picked_arena_id]},
        pack_arena_ids: %{"cards" => event.pack_arena_ids || []},
        pool_arena_ids: %{"cards" => []},
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
        "DraftPickMade for unknown draft #{event.mtga_draft_id} — skipping"
      )
    end

    :ok
  end

  defp project(%DraftCompleted{} = event) do
    draft = Drafts.get_by_mtga_id(event.mtga_draft_id, event.player_id)

    if draft do
      attrs = %{
        mtga_draft_id: event.mtga_draft_id,
        player_id: event.player_id,
        card_pool_arena_ids: %{"ids" => event.card_pool_arena_ids || []},
        completed_at: event.occurred_at
      }

      Drafts.upsert_draft!(attrs)

      Log.info(
        :ingester,
        "projected DraftCompleted mtga_draft_id=#{event.mtga_draft_id} pool=#{length(event.card_pool_arena_ids || [])} cards"
      )
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

  defp derive_format("QuickDraft_" <> _), do: "quick_draft"
  defp derive_format("PremierDraft_" <> _), do: "premier_draft"
  defp derive_format("TradDraft_" <> _), do: "traditional_draft"
  defp derive_format(_), do: "unknown"

  defp extract_set_code(event_name) do
    case String.split(event_name, "_") do
      [_, set | _] -> set
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/drafts/draft_projection_test.exs 2>&1 | tail -15
```

Expected: All passing.

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: DraftProjection — format derivation, DraftCompleted handler, draft_for_test"
jj new
```

---

## Task 7: DraftProjection — Human Draft Handlers

**Files:**
- Modify: `test/scry_2/drafts/draft_projection_test.exs`
- Modify: `test/support/factory.ex`

- [ ] **Step 1: Add `build_human_draft_pack_offered` factory**

In `test/support/factory.ex`, after `build_draft_completed`:

```elixir
def build_human_draft_pack_offered(attrs \\ %{}) do
  defaults = %{
    player_id: nil,
    mtga_draft_id: "test-draft-" <> random_suffix(),
    pack_number: 1,
    pick_number: 1,
    pack_arena_ids: [91_234, 91_235, 91_236],
    occurred_at: DateTime.utc_now(:second)
  }

  struct(HumanDraftPackOffered, Map.merge(defaults, Map.new(attrs)))
end
```

Make sure `HumanDraftPackOffered` is aliased at the top of factory.ex alongside the other event aliases.

- [ ] **Step 2: Write failing tests**

Add to `test/scry_2/drafts/draft_projection_test.exs`:

```elixir
describe "HumanDraftPackOffered" do
  test "creates draft row if none exists yet" do
    event = Factory.build_human_draft_pack_offered(%{
      mtga_draft_id: "PremierDraft_FDN_20260401",
      pack_number: 1,
      pick_number: 2,
      pack_arena_ids: [11111, 22222, 33333]
    })

    Scry2.Drafts.DraftProjection.project_for_test(event)

    draft = Drafts.get_by_mtga_id("PremierDraft_FDN_20260401")
    assert draft != nil
    assert draft.format == "premier_draft"
    assert draft.set_code == "FDN"
  end

  test "stores pack_arena_ids on the pick row" do
    draft = Factory.create_draft(%{mtga_draft_id: "PremierDraft_FDN_20260401"})
    pack = [11111, 22222, 33333]

    event = Factory.build_human_draft_pack_offered(%{
      mtga_draft_id: draft.mtga_draft_id,
      player_id: draft.player_id,
      pack_number: 1,
      pick_number: 2,
      pack_arena_ids: pack
    })

    Scry2.Drafts.DraftProjection.project_for_test(event)

    updated = Drafts.get_draft_with_picks(draft.id)
    pick = Enum.find(updated.picks, &(&1.pack_number == 1 and &1.pick_number == 2))
    assert pick.pack_arena_ids == %{"cards" => pack}
    assert pick.picked_arena_id == nil
  end
end

describe "HumanDraftPickMade" do
  test "stamps picked_arena_id on an existing pick row (preserving pack contents)" do
    draft = Factory.create_draft(%{mtga_draft_id: "PremierDraft_FDN_20260401"})

    # Pack offered first
    offer = Factory.build_human_draft_pack_offered(%{
      mtga_draft_id: draft.mtga_draft_id,
      player_id: draft.player_id,
      pack_number: 1,
      pick_number: 2,
      pack_arena_ids: [11111, 22222, 33333]
    })
    Scry2.Drafts.DraftProjection.project_for_test(offer)

    # Pick made
    pick_event = Factory.build_human_draft_pick_made(%{
      mtga_draft_id: draft.mtga_draft_id,
      player_id: draft.player_id,
      pack_number: 1,
      pick_number: 2,
      picked_arena_ids: [11111]
    })
    Scry2.Drafts.DraftProjection.project_for_test(pick_event)

    updated = Drafts.get_draft_with_picks(draft.id)
    pick = Enum.find(updated.picks, &(&1.pack_number == 1 and &1.pick_number == 2))
    assert pick.picked_arena_id == 11111
    assert pick.pack_arena_ids == %{"cards" => [11111, 22222, 33333]}
  end
end
```

- [ ] **Step 3: Run tests to confirm they fail**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/drafts/draft_projection_test.exs 2>&1 | tail -20
```

- [ ] **Step 4: Run tests to confirm they pass**

The projection code was already written in Task 6. The tests should pass now. If they don't, debug the `upsert_pick!` merge behaviour — the key is that `upsert_pick!` finds an existing row by `(draft_id, pack_number, pick_number)` and merges attrs, so pack_arena_ids from the PackOffered upsert is preserved when PickMade upserts with only `picked_arena_id`.

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/drafts/draft_projection_test.exs 2>&1 | tail -10
```

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: DraftProjection human draft handlers + factory"
jj new
```

---

## Task 8: DraftProjection — Cross-Context Wins/Losses

**Files:**
- Modify: `lib/scry_2/drafts/draft_projection.ex`
- Modify: `test/scry_2/drafts/draft_projection_test.exs`

- [ ] **Step 1: Write failing test**

Add to `test/scry_2/drafts/draft_projection_test.exs`:

```elixir
describe "wins/losses from matches:updates" do
  test "updates draft wins and losses when a match for its event_name is broadcast" do
    player_id = 10
    event_name = "QuickDraft_FDN_20260401"
    draft = Factory.create_draft(%{player_id: player_id, mtga_draft_id: event_name, event_name: event_name})
    Factory.create_match(%{player_id: player_id, event_name: event_name, won: true})
    Factory.create_match(%{player_id: player_id, event_name: event_name, won: true})
    Factory.create_match(%{player_id: player_id, event_name: event_name, won: false})

    # Simulate receiving a match_updated broadcast
    Scry2.Drafts.DraftProjection.handle_extra_info_for_test({:match_updated, draft.id}, %{})

    updated = Drafts.get_by_mtga_id(event_name, player_id)
    assert updated.wins == 2
    assert updated.losses == 1
  end
end
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/drafts/draft_projection_test.exs --only "wins/losses" 2>&1 | tail -15
```

- [ ] **Step 3: Implement `handle_extra_info/2` and test helper**

Add to `lib/scry_2/drafts/draft_projection.ex` (after the `after_init/1`):

```elixir
if Mix.env() == :test do
  def handle_extra_info_for_test(msg, state), do: handle_extra_info(msg, state)
end

def handle_extra_info({:match_updated, match_id}, state) do
  case Matches.get_match(match_id) do
    nil ->
      {:noreply, state}

    match ->
      update_draft_record(match.event_name, match.player_id)
      {:noreply, state}
  end
end

defp update_draft_record(event_name, player_id) do
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
```

- [ ] **Step 4: Add `get_by_event_name/2` to `Scry2.Drafts`**

In `lib/scry_2/drafts.ex`, add:

```elixir
@doc "Returns the draft with the given event_name and optional player_id, or nil."
def get_by_event_name(event_name, player_id \\ nil) when is_binary(event_name) do
  Draft
  |> where([d], d.event_name == ^event_name)
  |> maybe_filter_by_player(player_id)
  |> Repo.one()
end
```

- [ ] **Step 5: Run all projection tests**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/drafts/draft_projection_test.exs 2>&1 | tail -10
```

Expected: All pass.

- [ ] **Step 6: Commit**

```bash
jj desc -m "feat: DraftProjection cross-context wins/losses from matches:updates PubSub"
jj new
```

---

## Task 9: DraftsHelpers — New Pure Functions

**Files:**
- Modify: `lib/scry_2_web/live/drafts_helpers.ex`
- Modify: `test/scry_2_web/live/drafts_helpers_test.exs` (create if absent)

- [ ] **Step 1: Write failing tests**

Create `test/scry_2_web/live/drafts_helpers_test.exs`:

```elixir
defmodule Scry2Web.DraftsHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.DraftsHelpers

  describe "trophy?/1" do
    test "true when wins == 7" do
      assert DraftsHelpers.trophy?(%{wins: 7})
    end

    test "false otherwise" do
      refute DraftsHelpers.trophy?(%{wins: 6})
      refute DraftsHelpers.trophy?(%{wins: nil})
    end
  end

  describe "win_rate/1" do
    test "computes win rate from wins/losses" do
      assert_in_delta DraftsHelpers.win_rate(%{wins: 7, losses: 2}), 0.777, 0.001
    end

    test "nil when no games played" do
      assert DraftsHelpers.win_rate(%{wins: nil, losses: nil}) == nil
      assert DraftsHelpers.win_rate(%{wins: 0, losses: 0}) == nil
    end
  end

  describe "format_label/1" do
    test "converts atom formats to human labels" do
      assert DraftsHelpers.format_label("quick_draft") == "Quick Draft"
      assert DraftsHelpers.format_label("premier_draft") == "Premier Draft"
      assert DraftsHelpers.format_label("traditional_draft") == "Traditional Draft"
      assert DraftsHelpers.format_label("unknown") == "Unknown"
      assert DraftsHelpers.format_label(nil) == "—"
    end
  end

  describe "group_pool_by_type/2" do
    test "groups cards by type using provided type lookup" do
      cards_by_arena_id = %{
        1 => %{type_line: "Creature — Wizard"},
        2 => %{type_line: "Instant"},
        3 => %{type_line: "Land"}
      }

      groups = DraftsHelpers.group_pool_by_type([1, 2, 3], cards_by_arena_id)

      assert Enum.find(groups, &(elem(&1, 0) == "Creatures")) != nil
      assert Enum.find(groups, &(elem(&1, 0) == "Instants & Sorceries")) != nil
      assert Enum.find(groups, &(elem(&1, 0) == "Lands")) != nil
    end

    test "unknown arena_ids are omitted" do
      groups = DraftsHelpers.group_pool_by_type([999], %{})
      assert groups == []
    end
  end

  describe "record_color_class/1" do
    test "emerald for win rate >= 55%" do
      assert DraftsHelpers.record_color_class(%{wins: 7, losses: 0}) == "text-success"
    end

    test "amber for 40-54%" do
      assert DraftsHelpers.record_color_class(%{wins: 4, losses: 6}) == "text-warning"
    end

    test "red for < 40%" do
      assert DraftsHelpers.record_color_class(%{wins: 1, losses: 9}) == "text-error"
    end

    test "muted for nil" do
      assert DraftsHelpers.record_color_class(%{wins: nil, losses: nil}) == "text-base-content/50"
    end
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/drafts_helpers_test.exs 2>&1 | tail -15
```

- [ ] **Step 3: Implement the helpers**

Replace `lib/scry_2_web/live/drafts_helpers.ex`:

```elixir
defmodule Scry2Web.DraftsHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.DraftsLive`. Extracted per ADR-013.
  """

  @type_groups [
    {"Creatures", ~w(Creature)},
    {"Instants & Sorceries", ~w(Instant Sorcery)},
    {"Artifacts & Enchantments", ~w(Artifact Enchantment)},
    {"Lands", ~w(Land)},
    {"Other", []}
  ]

  @doc "True when the draft has the maximum wins (trophy run)."
  @spec trophy?(map()) :: boolean()
  def trophy?(%{wins: 7}), do: true
  def trophy?(_), do: false

  @doc "Win rate as a float 0.0–1.0, or nil when no games played."
  @spec win_rate(map()) :: float() | nil
  def win_rate(%{wins: wins, losses: losses})
      when is_integer(wins) and is_integer(losses) and wins + losses > 0 do
    wins / (wins + losses)
  end

  def win_rate(_), do: nil

  @doc "Human-readable format label."
  @spec format_label(String.t() | nil) :: String.t()
  def format_label("quick_draft"), do: "Quick Draft"
  def format_label("premier_draft"), do: "Premier Draft"
  def format_label("traditional_draft"), do: "Traditional Draft"
  def format_label(nil), do: "—"
  def format_label(other), do: other |> String.split("_") |> Enum.map(&String.capitalize/1) |> Enum.join(" ")

  @doc """
  Groups a list of arena_ids by card type using a lookup map of
  `%{arena_id => %{type_line: string}}`. Returns `[{label, [arena_id]}]`
  in canonical order, omitting empty groups.
  """
  @spec group_pool_by_type([integer()], map()) :: [{String.t(), [integer()]}]
  def group_pool_by_type(arena_ids, cards_by_arena_id) do
    classified =
      arena_ids
      |> Enum.flat_map(fn arena_id ->
        case Map.get(cards_by_arena_id, arena_id) do
          nil -> []
          card -> [{arena_id, classify_type(card.type_line)}]
        end
      end)

    @type_groups
    |> Enum.map(fn {label, _keywords} ->
      cards =
        classified
        |> Enum.filter(fn {_id, group} -> group == label end)
        |> Enum.map(&elem(&1, 0))

      {label, cards}
    end)
    |> Enum.reject(fn {_label, cards} -> cards == [] end)
  end

  @doc "Tailwind CSS color class based on win rate."
  @spec record_color_class(map()) :: String.t()
  def record_color_class(draft) do
    case win_rate(draft) do
      nil -> "text-base-content/50"
      rate when rate >= 0.55 -> "text-success"
      rate when rate >= 0.40 -> "text-warning"
      _ -> "text-error"
    end
  end

  @doc "Format a win-loss record for display."
  @spec win_loss_label(integer() | nil, integer() | nil) :: String.t()
  def win_loss_label(wins, losses), do: "#{wins || 0}–#{losses || 0}"

  @doc "Returns a human label for draft completion status."
  @spec draft_status_label(map()) :: String.t()
  def draft_status_label(%{completed_at: nil}), do: "In progress"
  def draft_status_label(_draft), do: "Complete"

  # Private

  defp classify_type(type_line) when is_binary(type_line) do
    cond do
      String.contains?(type_line, "Creature") -> "Creatures"
      String.contains?(type_line, "Instant") or String.contains?(type_line, "Sorcery") -> "Instants & Sorceries"
      String.contains?(type_line, "Artifact") or String.contains?(type_line, "Enchantment") -> "Artifacts & Enchantments"
      String.contains?(type_line, "Land") -> "Lands"
      true -> "Other"
    end
  end

  defp classify_type(_), do: "Other"
end
```

- [ ] **Step 4: Run tests**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/drafts_helpers_test.exs 2>&1 | tail -10
```

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: DraftsHelpers — trophy, win_rate, format_label, group_pool_by_type, record_color_class"
jj new
```

---

## Task 10: DraftsLive — List View

**Files:**
- Modify: `lib/scry_2_web/live/drafts_live.ex`
- Modify: `test/scry_2_web/live/drafts_live_test.exs`

- [ ] **Step 1: Write failing list view test**

In `test/scry_2_web/live/drafts_live_test.exs`:

```elixir
defmodule Scry2Web.DraftsLiveTest do
  use Scry2Web.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Scry2.TestFactory, as: Factory

  describe "list view (/drafts)" do
    test "shows stat cards", %{conn: conn} do
      player_id = setup_player(conn)
      Factory.create_draft(%{
        player_id: player_id,
        wins: 7, losses: 0,
        completed_at: DateTime.utc_now(:second),
        format: "quick_draft", set_code: "FDN"
      })
      Factory.create_draft(%{
        player_id: player_id,
        wins: 3, losses: 3,
        completed_at: DateTime.utc_now(:second),
        format: "premier_draft", set_code: "FDN"
      })

      {:ok, view, _html} = live(conn, ~p"/drafts")

      assert has_element?(view, "[data-stat='total-drafts']", "2")
      assert has_element?(view, "[data-stat='trophies']", "1")
    end

    test "shows format filter chips", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/drafts")
      assert has_element?(view, "[data-filter='format']")
    end

    test "filters list by format", %{conn: conn} do
      player_id = setup_player(conn)
      Factory.create_draft(%{player_id: player_id, format: "quick_draft", set_code: "FDN"})
      Factory.create_draft(%{player_id: player_id, format: "premier_draft", set_code: "FDN"})

      {:ok, _view, html} = live(conn, ~p"/drafts?format=quick_draft")

      assert html =~ "Quick Draft"
      refute html =~ "Premier Draft"
    end
  end
end
```

> Note: `setup_player/1` must be a test helper that sets the active player in the session/conn. Check `test/support/conn_case.ex` for how MatchesLiveTest does this.

- [ ] **Step 2: Run test to confirm it fails**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/drafts_live_test.exs 2>&1 | tail -20
```

- [ ] **Step 3: Rewrite `DraftsLive` — list view only**

Replace `lib/scry_2_web/live/drafts_live.ex` with the list + stub detail below. The detail tabs will be filled in Tasks 11–13.

```elixir
defmodule Scry2Web.DraftsLive do
  use Scry2Web, :live_view

  import Scry2Web.LiveHelpers
  import Scry2Web.DraftsHelpers, warn: false

  alias Scry2.Cards
  alias Scry2.Drafts
  alias Scry2.Matches
  alias Scry2.Topics

  @formats ~w(quick_draft premier_draft traditional_draft)
  @default_tab :picks

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.drafts_updates())
    {:ok, assign(socket, reload_timer: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    player_id = socket.assigns[:active_player_id]

    case params do
      %{"id" => id} ->
        tab = parse_tab(params["tab"])
        draft = Drafts.get_draft_with_picks(String.to_integer(id))
        socket = assign_detail(socket, draft, tab, player_id)
        {:noreply, assign(socket, page: :detail)}

      _ ->
        format = params["format"]
        set_code = params["set"]
        stats = Drafts.draft_stats(player_id: player_id)
        drafts = Drafts.list_drafts(player_id: player_id, format: format, set_code: set_code, limit: 50)
        set_codes = drafts |> Enum.map(& &1.set_code) |> Enum.uniq() |> Enum.reject(&is_nil/1)

        socket =
          assign(socket,
            page: :list,
            stats: stats,
            drafts: drafts,
            format_filter: format,
            set_filter: set_code,
            available_sets: set_codes
          )

        {:noreply, socket}
    end
  end

  defp assign_detail(socket, draft, tab, player_id) do
    base =
      assign(socket,
        draft: draft,
        active_tab: tab,
        picks: [],
        submitted_decks: [],
        event_matches: [],
        card_pool_groups: [],
        cards_by_arena_id: %{}
      )

    case tab do
      :picks ->
        arena_ids = all_pack_arena_ids(draft)
        cards_by_arena_id = Cards.get_cards_by_arena_id(arena_ids)
        assign(base, cards_by_arena_id: cards_by_arena_id)

      :deck ->
        pool_ids = pool_arena_ids(draft)
        cards_by_arena_id = Cards.get_cards_by_arena_id(pool_ids)
        groups = group_pool_by_type(pool_ids, cards_by_arena_id)
        decks = if draft, do: Matches.list_decks_for_event(draft.event_name, player_id), else: []

        assign(base, card_pool_groups: groups, cards_by_arena_id: cards_by_arena_id, submitted_decks: decks)

      :matches ->
        event_matches = if draft, do: Matches.list_matches_for_event(draft.event_name, player_id), else: []
        assign(base, event_matches: event_matches)
    end
  end

  @impl true
  def handle_info({:draft_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]
    stats = Drafts.draft_stats(player_id: player_id)
    drafts = Drafts.list_drafts(player_id: player_id, format: socket.assigns[:format_filter], limit: 50)
    {:noreply, assign(socket, stats: stats, drafts: drafts, reload_timer: nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(%{page: :list} = assigns) do
    sets = Map.get(assigns, :available_sets, [])
    assigns = assign(assigns, :available_sets, sets)

    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id} current_path={@player_scope_uri}>
      <h1 class="text-2xl font-semibold font-beleren">Drafts</h1>

      <%!-- Stats Dashboard --%>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mt-4">
        <.stat_card title="Total Drafts" value={@stats.total} data-stat="total-drafts" />
        <.stat_card
          title="Win Rate"
          value={if @stats.win_rate, do: "#{round(@stats.win_rate * 100)}%", else: "—"}
        />
        <.stat_card
          title="Avg Wins"
          value={if @stats.avg_wins, do: Float.round(@stats.avg_wins, 1) |> to_string(), else: "—"}
        />
        <.stat_card title="Trophies" value={@stats.trophies} data-stat="trophies" />
      </div>

      <%!-- Format Breakdown --%>
      <div :if={@stats.by_format != []} class="card bg-base-200 mt-3 p-4">
        <div class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-3">By Format</div>
        <div class="flex flex-col gap-2">
          <div :for={row <- @stats.by_format} class="flex items-center gap-3">
            <span class="text-sm w-36 shrink-0">{format_label(row.format)}</span>
            <div class="flex-1 bg-base-300 rounded-full h-1.5 overflow-hidden">
              <div
                class={["h-full rounded-full", format_bar_color(row.win_rate)]}
                style={"width: #{round((row.win_rate || 0) * 100)}%"}
              />
            </div>
            <span class={["text-xs w-20 text-right tabular-nums", format_win_rate_color(row.win_rate)]}>
              {if row.win_rate, do: "#{round(row.win_rate * 100)}%", else: "—"} ({row.total})
            </span>
          </div>
        </div>
      </div>

      <%!-- Filters --%>
      <div class="flex flex-wrap items-center gap-2 mt-4" data-filter="format">
        <.link
          patch={~p"/drafts"}
          class={["btn btn-xs", if(is_nil(@format_filter), do: "btn-soft btn-primary", else: "btn-ghost")]}
        >
          All Formats
        </.link>
        <.link
          :for={fmt <- @(~w(quick_draft premier_draft traditional_draft))}
          patch={~p"/drafts?format=#{fmt}#{if @set_filter, do: "&set=#{@set_filter}", else: ""}"}
          class={["btn btn-xs", if(@format_filter == fmt, do: "btn-soft btn-primary", else: "btn-ghost")]}
        >
          {format_label(fmt)}
        </.link>

        <div class="flex-1" />

        <.link
          :for={set <- @available_sets}
          patch={~p"/drafts?set=#{set}#{if @format_filter, do: "&format=#{@format_filter}", else: ""}"}
          class={["btn btn-xs", if(@set_filter == set, do: "btn-soft btn-primary", else: "btn-ghost")]}
        >
          {set}
        </.link>
      </div>

      <.empty_state :if={@drafts == []}>
        No drafts recorded yet.
      </.empty_state>

      <%!-- Draft List --%>
      <div :if={@drafts != []} class="overflow-x-auto mt-3">
        <table class="table table-sm table-zebra">
          <thead>
            <tr class="text-xs text-base-content/60 uppercase">
              <th>Date</th>
              <th>Set</th>
              <th>Format</th>
              <th>Record</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={draft <- @drafts} class="hover cursor-pointer" phx-click={JS.navigate(~p"/drafts/#{draft.id}")}>
              <td>{format_datetime(draft.started_at)}</td>
              <td>{draft.set_code || "—"}</td>
              <td class="text-base-content/60">{format_label(draft.format)}</td>
              <td>
                <span class={["font-semibold tabular-nums", record_color_class(draft)]}>
                  {win_loss_label(draft.wins, draft.losses)}
                </span>
                <span :if={trophy?(draft)} class="ml-1 badge badge-xs badge-warning">Trophy</span>
              </td>
              <td class={["text-xs", if(is_nil(draft.completed_at), do: "text-warning", else: "text-success")]}>
                {draft_status_label(draft)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  def render(%{page: :detail} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id} current_path={@player_scope_uri}>
      <.back_link navigate={~p"/drafts"} label="All drafts" />

      <%!-- Header --%>
      <div class="mt-2">
        <h1 class="text-2xl font-semibold font-beleren">
          {@draft.set_code} {format_label(@draft.format)}
        </h1>
        <div class="flex items-center gap-3 mt-1">
          <span class={["text-2xl font-black tabular-nums", record_color_class(@draft)]}>
            {win_loss_label(@draft.wins, @draft.losses)}
          </span>
          <span :if={trophy?(@draft)} class="badge badge-warning">Trophy</span>
          <span class="text-sm text-base-content/50">{format_datetime(@draft.started_at)}</span>
          <span
            :if={is_nil(@draft.completed_at)}
            class="badge badge-warning badge-outline badge-sm"
          >
            In Progress
          </span>
        </div>
      </div>

      <%!-- Tabs --%>
      <div class="flex gap-0 border-b border-base-300 mt-4 mb-5">
        <.tab_link label="Picks" tab={:picks} active={@active_tab} draft={@draft} />
        <.tab_link label="Deck" tab={:deck} active={@active_tab} draft={@draft} />
        <.tab_link label="Matches" tab={:matches} active={@active_tab} draft={@draft} />
      </div>

      <.picks_tab :if={@active_tab == :picks} draft={@draft} cards_by_arena_id={@cards_by_arena_id} />
      <.deck_tab :if={@active_tab == :deck} draft={@draft} card_pool_groups={@card_pool_groups} cards_by_arena_id={@cards_by_arena_id} submitted_decks={@submitted_decks} />
      <.matches_tab :if={@active_tab == :matches} matches={@event_matches} />
    </Layouts.app>
    """
  end

  # --- Components ---

  attr :label, :string, required: true
  attr :tab, :atom, required: true
  attr :active, :atom, required: true
  attr :draft, :map, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={~p"/drafts/#{@draft.id}?tab=#{@tab}"}
      class={[
        "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
        if(@tab == @active,
          do: "border-primary text-primary",
          else: "border-transparent text-base-content/50 hover:text-base-content"
        )
      ]}
    >
      {@label}
    </.link>
    """
  end

  # Stub components — filled in Tasks 11-13
  defp picks_tab(assigns), do: ~H"<div>Picks coming soon</div>"
  defp deck_tab(assigns), do: ~H"<div>Deck coming soon</div>"
  defp matches_tab(assigns), do: ~H"<div>Matches coming soon</div>"

  # Helpers

  defp parse_tab("deck"), do: :deck
  defp parse_tab("matches"), do: :matches
  defp parse_tab(_), do: :picks

  defp all_pack_arena_ids(nil), do: []
  defp all_pack_arena_ids(%{picks: picks}) do
    picks
    |> Enum.flat_map(fn pick ->
      picked = if pick.picked_arena_id, do: [pick.picked_arena_id], else: []
      pack = (pick.pack_arena_ids || %{})["cards"] || []
      picked ++ pack
    end)
    |> Enum.uniq()
  end

  defp pool_arena_ids(nil), do: []
  defp pool_arena_ids(%{card_pool_arena_ids: %{"ids" => ids}}) when is_list(ids), do: ids
  defp pool_arena_ids(_), do: []

  defp format_bar_color(rate) when is_float(rate) and rate >= 0.55, do: "bg-success"
  defp format_bar_color(rate) when is_float(rate) and rate >= 0.40, do: "bg-warning"
  defp format_bar_color(_), do: "bg-error"

  defp format_win_rate_color(rate) when is_float(rate) and rate >= 0.55, do: "text-success"
  defp format_win_rate_color(rate) when is_float(rate) and rate >= 0.40, do: "text-warning"
  defp format_win_rate_color(_), do: "text-error"
end
```

> **Note:** `Cards.get_cards_by_arena_id/1` — check if this function exists in `lib/scry_2/cards.ex`. If not, add it: `def get_cards_by_arena_id(ids), do: Repo.all(from c in Card, where: c.arena_id in ^ids, select: {c.arena_id, c}) |> Map.new()`.

- [ ] **Step 4: Run tests**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/drafts_live_test.exs 2>&1 | tail -15
```

- [ ] **Step 5: Verify the page loads in dev**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix phx.server
```

Navigate to `http://localhost:4444/drafts` and confirm the stats dashboard and list render without errors.

- [ ] **Step 6: Commit**

```bash
jj desc -m "feat: DraftsLive list view — stats dashboard, format/set filters, redesigned table"
jj new
```

---

## Task 11: DraftsLive — Picks Tab

**Files:**
- Modify: `lib/scry_2_web/live/drafts_live.ex`

- [ ] **Step 1: Add picks tab test**

Add to `test/scry_2_web/live/drafts_live_test.exs`:

```elixir
describe "detail — picks tab" do
  test "renders pack sections with picked card highlighted", %{conn: conn} do
    player_id = setup_player(conn)
    draft = Factory.create_draft(%{player_id: player_id})
    Factory.create_pick(%{
      draft: draft,
      pack_number: 1,
      pick_number: 1,
      picked_arena_id: 91_234,
      pack_arena_ids: %{"cards" => [91_234, 91_235]}
    })

    {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}?tab=picks")

    assert has_element?(view, "[data-pack='1-1']")
    assert has_element?(view, "[data-picked='91234']")
  end
end
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/drafts_live_test.exs --only "picks tab" 2>&1 | tail -15
```

- [ ] **Step 3: Replace the `picks_tab` stub**

In `lib/scry_2_web/live/drafts_live.ex`, replace the stub `defp picks_tab(assigns)` with:

```elixir
attr :draft, :map, required: true
attr :cards_by_arena_id, :map, required: true

defp picks_tab(assigns) do
  grouped =
    (assigns.draft.picks || [])
    |> Enum.group_by(&{&1.pack_number, &1.pick_number})
    |> Enum.sort_by(fn {{pack, pick}, _} -> {pack, pick} end)

  assigns = assign(assigns, :grouped_picks, grouped)

  ~H"""
  <.empty_state :if={@draft.picks == []}>
    No picks recorded yet.
  </.empty_state>

  <div :for={{{pack_num, pick_num}, [pick | _]} <- @grouped_picks} class="mb-8">
    <div
      class="text-xs font-medium text-base-content/40 uppercase tracking-widest mb-3"
      data-pack={"#{pack_num}-#{pick_num}"}
    >
      Pack {@(pick.pack_number)} · Pick {@(pick.pick_number)}
    </div>

    <%!-- No pack contents for P1P1 in human drafts --%>
    <p
      :if={(pick.pack_arena_ids["cards"] || []) == [] and not is_nil(pick.picked_arena_id)}
      class="text-xs text-base-content/40 italic mb-2"
    >
      Pack contents unavailable for this pick.
    </p>

    <div class="flex flex-wrap gap-2">
      <div
        :for={arena_id <- (pick.pack_arena_ids["cards"] || [])}
        class="relative"
      >
        <.card_image
          id={"pick-#{pick.draft_id}-#{pack_num}-#{pick_num}-#{arena_id}"}
          arena_id={arena_id}
          name={get_in(@cards_by_arena_id, [arena_id, :name]) || ""}
          class={[
            "w-[72px]",
            if(arena_id == pick.picked_arena_id,
              do: "ring-2 ring-primary rounded-[5px]",
              else: "opacity-40"
            )
          ]}
          data-picked={if arena_id == pick.picked_arena_id, do: to_string(arena_id)}
        />
        <%!-- Checkmark badge on picked card --%>
        <div
          :if={arena_id == pick.picked_arena_id}
          class="absolute top-1 right-1 w-5 h-5 rounded-full bg-primary flex items-center justify-center pointer-events-none"
        >
          <.icon name="hero-check-micro" class="w-3 h-3 text-primary-content" />
        </div>
      </div>

      <%!-- Picked card with no pack data (first human pick) --%>
      <div
        :if={(pick.pack_arena_ids["cards"] || []) == [] and not is_nil(pick.picked_arena_id)}
        class="relative"
      >
        <.card_image
          id={"pick-solo-#{pick.draft_id}-#{pack_num}-#{pick_num}"}
          arena_id={pick.picked_arena_id}
          name={get_in(@cards_by_arena_id, [pick.picked_arena_id, :name]) || ""}
          class="w-[72px] ring-2 ring-primary rounded-[5px]"
          data-picked={to_string(pick.picked_arena_id)}
        />
        <div class="absolute top-1 right-1 w-5 h-5 rounded-full bg-primary flex items-center justify-center pointer-events-none">
          <.icon name="hero-check-micro" class="w-3 h-3 text-primary-content" />
        </div>
      </div>
    </div>
  </div>
  """
end
```

- [ ] **Step 4: Run tests**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/drafts_live_test.exs 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: DraftsLive picks tab — full pack view with card images and picked highlight"
jj new
```

---

## Task 12: DraftsLive — Deck Tab

**Files:**
- Modify: `lib/scry_2_web/live/drafts_live.ex`

- [ ] **Step 1: Add deck tab test**

Add to `test/scry_2_web/live/drafts_live_test.exs`:

```elixir
describe "detail — deck tab" do
  test "shows submitted decks section", %{conn: conn} do
    player_id = setup_player(conn)
    event_name = "QuickDraft_FDN_20260401"
    draft = Factory.create_draft(%{player_id: player_id, mtga_draft_id: event_name, event_name: event_name})
    Factory.create_match(%{
      player_id: player_id,
      event_name: event_name,
      mtga_deck_id: "deck-abc",
      deck_name: "UR Control"
    })

    {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}?tab=deck")

    assert has_element?(view, "[data-section='submitted-decks']")
    assert has_element?(view, "[data-deck='deck-abc']")
  end

  test "shows pool section when card_pool_arena_ids present", %{conn: conn} do
    player_id = setup_player(conn)
    draft = Factory.create_draft(%{
      player_id: player_id,
      card_pool_arena_ids: %{"ids" => [91_234]}
    })

    {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}?tab=deck")

    assert has_element?(view, "[data-section='draft-pool']")
  end
end
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/drafts_live_test.exs --only "deck tab" 2>&1 | tail -15
```

- [ ] **Step 3: Replace the `deck_tab` stub**

```elixir
attr :draft, :map, required: true
attr :card_pool_groups, :list, required: true
attr :cards_by_arena_id, :map, required: true
attr :submitted_decks, :list, required: true

defp deck_tab(assigns) do
  ~H"""
  <%!-- Submitted Decks --%>
  <div data-section="submitted-decks">
    <h3 class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-3">
      Submitted Decks
    </h3>

    <.empty_state :if={@submitted_decks == []}>
      No match data yet — decks appear after the first match is played.
    </.empty_state>

    <div class="flex flex-col gap-2 mb-8">
      <.link
        :for={deck <- @submitted_decks}
        navigate={~p"/decks/#{deck.mtga_deck_id}"}
        class="card bg-base-200 hover:bg-base-300 transition-colors cursor-pointer"
        data-deck={deck.mtga_deck_id}
      >
        <div class="card-body py-3 px-4">
          <div class="flex items-center justify-between">
            <div>
              <div class="font-medium">{deck.deck_name || deck.mtga_deck_id}</div>
              <div class="text-xs text-base-content/50 mt-0.5">
                <.mana_pips colors={deck.deck_colors} class="text-[0.65rem]" />
              </div>
            </div>
            <.icon name="hero-arrow-right-micro" class="w-4 h-4 text-base-content/30" />
          </div>
        </div>
      </.link>
    </div>
  </div>

  <%!-- Full Draft Pool --%>
  <div data-section="draft-pool">
    <h3 class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-3">
      Full Draft Pool
    </h3>

    <.empty_state :if={@card_pool_groups == []}>
      Pool available after the draft is complete.
    </.empty_state>

    <div class="flex flex-wrap gap-8">
      <div :for={{type_label, arena_ids} <- @card_pool_groups}>
        <div class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-2">
          {type_label} ({length(arena_ids)})
        </div>
        <div class="flex gap-1 flex-wrap">
          <.card_image
            :for={arena_id <- arena_ids}
            id={"pool-#{@draft.id}-#{arena_id}"}
            arena_id={arena_id}
            name={get_in(@cards_by_arena_id, [arena_id, :name]) || ""}
            class="w-[56px]"
          />
        </div>
      </div>
    </div>
  </div>
  """
end
```

- [ ] **Step 4: Run tests**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/drafts_live_test.exs 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: DraftsLive deck tab — submitted decks + type-grouped pool with card images"
jj new
```

---

## Task 13: DraftsLive — Matches Tab + Final Cleanup

**Files:**
- Modify: `lib/scry_2_web/live/drafts_live.ex`
- Run: `mix precommit`

- [ ] **Step 1: Add matches tab test**

Add to `test/scry_2_web/live/drafts_live_test.exs`:

```elixir
describe "detail — matches tab" do
  test "shows matches with deck link", %{conn: conn} do
    player_id = setup_player(conn)
    event_name = "QuickDraft_FDN_20260401"
    draft = Factory.create_draft(%{player_id: player_id, mtga_draft_id: event_name, event_name: event_name})
    match = Factory.create_match(%{
      player_id: player_id,
      event_name: event_name,
      won: true,
      opponent_screen_name: "StormCrow88",
      mtga_deck_id: "deck-abc",
      deck_name: "UR Control"
    })

    {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}?tab=matches")

    assert has_element?(view, "[data-match='#{match.id}']")
    assert has_element?(view, "[data-deck-link='deck-abc']")
    assert view |> render() =~ "StormCrow88"
  end
end
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/drafts_live_test.exs --only "matches tab" 2>&1 | tail -15
```

- [ ] **Step 3: Replace the `matches_tab` stub**

```elixir
attr :matches, :list, required: true

defp matches_tab(assigns) do
  ~H"""
  <.empty_state :if={@matches == []}>
    No matches recorded for this draft yet.
  </.empty_state>

  <div :if={@matches != []} class="overflow-x-auto">
    <table class="table table-sm">
      <thead>
        <tr class="text-xs text-base-content/60 uppercase">
          <th>Result</th>
          <th>Opponent</th>
          <th>Deck</th>
          <th>Date</th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={match <- @matches}
          class="hover cursor-pointer"
          data-match={match.id}
          phx-click={JS.navigate(~p"/matches/#{match.id}")}
        >
          <td>
            <span class={if match.won, do: "font-bold text-success", else: "font-bold text-error"}>
              {if match.won, do: "W", else: "L"}
            </span>
          </td>
          <td>
            <div>{match.opponent_screen_name || "—"}</div>
            <div :if={match.opponent_rank} class="flex items-center gap-1 mt-0.5">
              <.rank_icon rank={match.opponent_rank} format_type={match.format_type} class="h-3" />
              <span class="text-xs text-base-content/40">{match.opponent_rank}</span>
            </div>
          </td>
          <td>
            <.link
              :if={match.mtga_deck_id}
              navigate={~p"/decks/#{match.mtga_deck_id}"}
              class="link link-hover text-sm"
              data-deck-link={match.mtga_deck_id}
            >
              {match.deck_name || match.mtga_deck_id}
            </.link>
            <span :if={is_nil(match.mtga_deck_id)} class="text-base-content/40 text-sm">—</span>
          </td>
          <td class="text-sm text-base-content/50">{format_datetime(match.started_at)}</td>
        </tr>
      </tbody>
    </table>
  </div>
  """
end
```

- [ ] **Step 4: Run all tests**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/drafts_live_test.exs 2>&1 | tail -10
```

- [ ] **Step 5: Run full test suite**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test 2>&1 | tail -20
```

Expected: All tests pass, zero warnings.

- [ ] **Step 6: Run precommit**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit
```

Fix any issues before committing.

- [ ] **Step 7: Reingest to verify end-to-end**

In the running dev REPL:
```elixir
Scry2.Events.reset_all!()
```

Then restart the watcher via tidewave. Confirm:
- Bot draft picks reappear in `/drafts`
- Stats dashboard shows correct totals
- Detail view picks tab shows card images with highlighted picks
- Trophies badge appears for 7-win drafts

- [ ] **Step 8: Check runtime errors**

```elixir
# via tidewave
mcp__tidewave__get_logs(level: "error")
```

Expected: No new errors from draft projection or LiveView.

- [ ] **Step 9: Commit**

```bash
jj desc -m "feat: DraftsLive matches tab — complete three-tab detail view"
jj new
```

---

## Known Risk

**Human draft `mtga_draft_id` correlation**: `HumanDraftPackOffered` uses `draftId` from `Draft.Notify` (a UUID-style identifier), while `DraftCompleted` derives `mtga_draft_id` from `EventName` (e.g., `"PremierDraft_FDN_20260401"`). Without actual human draft log samples, these IDs may not match, causing `DraftCompleted` to fail to find the existing draft row. This is a known gap that requires real Premier/Traditional Draft logs to verify and fix. The `IdentifyDomainEvents` module may need adjustment once log samples are captured.
