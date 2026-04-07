# Mulligans Show Don't Hide — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the mulligans view to show card images inline with orange Keep / blue Mulligan badges — no table, no clicking into rows.

**Architecture:** Update helper functions to return new badge/border classes, replace the table-based render with card-row layout using `<.card_hand>`, and call `ImageCache.ensure_cached` in the data loading path to pre-cache images before rendering.

**Tech Stack:** Phoenix LiveView, DaisyUI/Tailwind, `Scry2Web.CardComponents`, `Scry2.Cards.ImageCache`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/scry_2_web/live/mulligans_helpers.ex` | Modify | Update badge classes, add `decision_border_class/1` |
| `test/scry_2_web/live/mulligans_helpers_test.exs` | Modify | Update badge assertions, add border class tests |
| `lib/scry_2_web/live/mulligans_live.ex` | Modify | Replace table with card-row layout, add `ensure_cached` |

---

### Task 1: Update helpers — badge and border classes (TDD)

**Files:**
- Modify: `lib/scry_2_web/live/mulligans_helpers.ex`
- Modify: `test/scry_2_web/live/mulligans_helpers_test.exs`

- [ ] **Step 1: Update failing tests**

In `test/scry_2_web/live/mulligans_helpers_test.exs`, update the `decision_badge_class/1` test and add a new `decision_border_class/1` test:

```elixir
  describe "decision_badge_class/1" do
    test "returns badge classes" do
      assert MulligansHelpers.decision_badge_class(:kept) == "badge-warning badge-outline"
      assert MulligansHelpers.decision_badge_class(:mulliganed) == "badge-info badge-outline"
    end
  end

  describe "decision_border_class/1" do
    test "returns border accent classes" do
      assert MulligansHelpers.decision_border_class(:kept) == "border-warning"
      assert MulligansHelpers.decision_border_class(:mulliganed) == "border-info"
    end
  end
```

- [ ] **Step 2: Run tests to verify RED**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/mulligans_helpers_test.exs
```

Expected: `decision_badge_class` assertions fail (old values), `decision_border_class` undefined.

- [ ] **Step 3: Implement changes**

In `lib/scry_2_web/live/mulligans_helpers.ex`, update `decision_badge_class/1`:

```elixir
  @spec decision_badge_class(:kept | :mulliganed) :: String.t()
  def decision_badge_class(:kept), do: "badge-warning badge-outline"
  def decision_badge_class(:mulliganed), do: "badge-info badge-outline"
```

Add `decision_border_class/1` below it:

```elixir
  @doc """
  Returns a CSS border class for the hand row accent.
  """
  @spec decision_border_class(:kept | :mulliganed) :: String.t()
  def decision_border_class(:kept), do: "border-warning"
  def decision_border_class(:mulliganed), do: "border-info"
```

- [ ] **Step 4: Run tests to verify GREEN**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/mulligans_helpers_test.exs
```

Expected: all pass.

---

### Task 2: Redesign MulligansLive render + add ensure_cached

**Files:**
- Modify: `lib/scry_2_web/live/mulligans_live.ex`

- [ ] **Step 1: Update `load_mulligans/1` to pre-cache images**

Replace the existing `load_mulligans/1` private function:

```elixir
  defp load_mulligans(player_id) do
    matches =
      Events.list_mulligans(player_id: player_id)
      |> MulligansHelpers.group_by_match()

    # Pre-cache card images for all hands so the browser gets instant hits.
    arena_ids =
      matches
      |> Enum.flat_map(fn %{hands: hands} ->
        Enum.flat_map(hands, fn {offer, _decision} ->
          offer.hand_arena_ids || []
        end)
      end)
      |> Enum.uniq()

    if arena_ids != [], do: Scry2.Cards.ImageCache.ensure_cached(arena_ids)

    matches
  end
```

- [ ] **Step 2: Replace the `render/1` function**

Replace the entire `render/1` function with the card-row layout:

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold mb-4">Mulligans</h1>

      <.empty_state :if={@matches == []}>
        No mulligan data recorded yet. Play a game with MTGA detailed logs enabled.
      </.empty_state>

      <div :for={match <- @matches} class="mb-8">
        <div class="flex items-center gap-2 mb-3">
          <h2 class="text-sm font-semibold text-base-content/50 uppercase tracking-wider">
            Match
          </h2>
          <.link
            :if={match.match_id}
            navigate={~p"/events?match_id=#{match.match_id}"}
            class="font-mono text-xs text-accent/70 hover:text-accent"
          >
            {truncate_id(match.match_id)}
          </.link>
        </div>

        <div class="flex flex-col gap-2">
          <div
            :for={{offer, decision} <- match.hands}
            class={[
              "flex items-center gap-4 px-4 py-3 rounded-lg",
              "bg-base-200/50 border-l-[3px]",
              MulligansHelpers.decision_border_class(decision)
            ]}
          >
            <div class="min-w-[80px]">
              <span class={["badge badge-sm", MulligansHelpers.decision_badge_class(decision)]}>
                {MulligansHelpers.decision_label(decision)}
              </span>
            </div>

            <div :if={offer.hand_arena_ids} class="flex-1">
              <.card_hand arena_ids={offer.hand_arena_ids} class="w-12" />
            </div>
            <span :if={!offer.hand_arena_ids} class="flex-1 text-base-content/30">
              —
            </span>

            <span class="text-xs text-base-content/40 tabular-nums whitespace-nowrap">
              {offer.hand_size} cards
            </span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
```

- [ ] **Step 3: Add alias for ImageCache at the top of the module**

Add to the alias block at the top (after existing aliases):

```elixir
  alias Scry2.Cards.ImageCache
```

Note: `ImageCache` is only used in `load_mulligans/1`. If the existing code uses `Scry2.Cards.ImageCache.ensure_cached` fully qualified, the alias is optional but cleaner.

- [ ] **Step 4: Verify compilation**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warnings-as-errors
```

Expected: zero warnings.

- [ ] **Step 5: Run full test suite**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit
```

Expected: all pass, zero warnings.

---

### Task 3: Visual verification

- [ ] **Step 1: Open http://localhost:4002/mulligans in the browser**

Verify:
- Each hand shows card images (or placeholder if no arena_ids)
- Keep hands have orange left border + orange "Kept" badge
- Mulliganed hands have blue left border + blue "Mulliganed" badge
- Hands grouped by match, newest match first
- Card count shown on the right
- Match ID links to event explorer
- Empty state shows when no data
