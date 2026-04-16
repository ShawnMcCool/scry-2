# VS Opponent Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the inline "vs opponent" section from `MatchesLive` into a reusable `<.opponent_panel>` component with a stats row (Record + Win Rate) and a cumulative win rate chart when sufficient history exists.

**Architecture:** A new `OpponentComponents` module (in `components/`) registers `<.opponent_panel>` and is added to `html_helpers()` in `scry_2_web.ex` so it's available everywhere. A companion `OpponentHelpers` module (in `live/`) holds the pure computation (record counts, win rate, chart series, latest rank). The existing `LiveHelpers.cumulative_winrate_series/1` is reused for chart encoding; no new query functions are needed — the LiveView already fetches the history via `Matches.opponent_matches/2`.

**Tech Stack:** Elixir, Phoenix LiveView, HEEx, ECharts via `phx-hook="Chart"` (existing hook, `cumulative_winrate` chart type), daisyUI `stat_card`.

---

## File Map

| Path | Status | Responsibility |
|------|--------|----------------|
| `lib/scry_2_web/live/opponent_helpers.ex` | **Create** | Pure helpers: record counts, win rate, chart series, latest rank |
| `lib/scry_2_web/components/opponent_components.ex` | **Create** | `<.opponent_panel>` component |
| `lib/scry_2_web.ex` | **Modify** | Add `import Scry2Web.OpponentComponents` to `html_helpers/0` |
| `lib/scry_2_web/live/matches_live.ex` | **Modify** | Replace private `opponent_history/1` with `<.opponent_panel>` |
| `test/scry_2_web/live/opponent_helpers_test.exs` | **Create** | Unit tests for `OpponentHelpers` |

---

## Task 1: OpponentHelpers — tests and implementation

**Files:**
- Create: `lib/scry_2_web/live/opponent_helpers.ex`
- Create: `test/scry_2_web/live/opponent_helpers_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/scry_2_web/live/opponent_helpers_test.exs`:

```elixir
defmodule Scry2Web.OpponentHelpersTest do
  use ExUnit.Case, async: true

  import Scry2.TestFactory

  alias Scry2Web.OpponentHelpers

  describe "record/1" do
    test "returns {0, 0} for empty history" do
      assert OpponentHelpers.record([]) == {0, 0}
    end

    test "counts wins and losses" do
      history = [
        build_match(won: true),
        build_match(won: true),
        build_match(won: false)
      ]

      assert OpponentHelpers.record(history) == {2, 1}
    end

    test "ignores matches with nil won" do
      history = [
        build_match(won: true),
        build_match(won: nil)
      ]

      assert OpponentHelpers.record(history) == {1, 0}
    end
  end

  describe "win_rate/2" do
    test "returns nil when both counts are zero" do
      assert OpponentHelpers.win_rate(0, 0) == nil
    end

    test "returns 100.0 for all wins" do
      assert OpponentHelpers.win_rate(3, 0) == 100.0
    end

    test "returns 0.0 for all losses" do
      assert OpponentHelpers.win_rate(0, 3) == 0.0
    end

    test "returns rounded percentage for mixed record" do
      # 2/3 = 66.666...% rounded to 1 decimal
      assert OpponentHelpers.win_rate(2, 1) == 66.7
    end
  end

  describe "latest_rank/1" do
    test "returns nil for empty history" do
      assert OpponentHelpers.latest_rank([]) == nil
    end

    test "returns nil when all matches lack a rank" do
      history = [build_match(opponent_rank: nil)]
      assert OpponentHelpers.latest_rank(history) == nil
    end

    test "returns rank from the most recent match by started_at" do
      earlier = build_match(opponent_rank: "Gold 2", started_at: ~U[2026-01-01 10:00:00Z])
      later = build_match(opponent_rank: "Platinum 1", started_at: ~U[2026-01-02 10:00:00Z])

      # pass in reverse order to verify it selects by timestamp, not list position
      assert OpponentHelpers.latest_rank([later, earlier]) == "Platinum 1"
    end
  end

  describe "chart_series/1" do
    test "returns '[]' for fewer than 3 matches" do
      history = [build_match(), build_match()]
      assert OpponentHelpers.chart_series(history) == "[]"
    end

    test "returns JSON array of [timestamp, win_rate, label] triples with 3+ matches" do
      history = [
        build_match(won: true, started_at: ~U[2026-01-01 10:00:00Z]),
        build_match(won: true, started_at: ~U[2026-01-02 10:00:00Z]),
        build_match(won: false, started_at: ~U[2026-01-03 10:00:00Z])
      ]

      series = Jason.decode!(OpponentHelpers.chart_series(history))

      assert length(series) == 3
      [_timestamp, rate, label] = List.last(series)
      # 2 wins out of 3 = 66.7%
      assert rate == 66.7
      assert label == "2W–1L"
    end

    test "excludes matches with nil won from series" do
      history = [
        build_match(won: true, started_at: ~U[2026-01-01 10:00:00Z]),
        build_match(won: nil, started_at: ~U[2026-01-02 10:00:00Z]),
        build_match(won: true, started_at: ~U[2026-01-03 10:00:00Z]),
        build_match(won: false, started_at: ~U[2026-01-04 10:00:00Z])
      ]

      series = Jason.decode!(OpponentHelpers.chart_series(history))
      # 3 data points (nil excluded), not 4
      assert length(series) == 3
    end

    test "sorts matches by started_at regardless of input order" do
      # pass reversed — first match chronologically is a win so first point = 100%
      history = [
        build_match(won: false, started_at: ~U[2026-01-03 10:00:00Z]),
        build_match(won: true, started_at: ~U[2026-01-02 10:00:00Z]),
        build_match(won: true, started_at: ~U[2026-01-01 10:00:00Z])
      ]

      series = Jason.decode!(OpponentHelpers.chart_series(history))
      [_ts, first_rate, _label] = List.first(series)
      assert first_rate == 100.0
    end
  end
end
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
mix test test/scry_2_web/live/opponent_helpers_test.exs
```

Expected: compilation error — `Scry2Web.OpponentHelpers` does not exist.

- [ ] **Step 3: Create the implementation**

Create `lib/scry_2_web/live/opponent_helpers.ex`:

```elixir
defmodule Scry2Web.OpponentHelpers do
  @moduledoc """
  Pure helper functions for the `<.opponent_panel>` component.

  Input: a list of `%Scry2.Matches.Match{}` structs (previous matches against
  the same opponent, in any order).

  Output: computed display values — record counts, win rate, chart series,
  latest known rank.
  """

  alias Scry2Web.LiveHelpers

  @doc """
  Returns `{wins, losses}` counts from a list of matches.
  Matches with `nil` won (in-progress or unknown outcome) are ignored.
  """
  @spec record(list()) :: {non_neg_integer(), non_neg_integer()}
  def record(history) do
    wins = Enum.count(history, &(&1.won == true))
    losses = Enum.count(history, &(&1.won == false))
    {wins, losses}
  end

  @doc """
  Returns win rate as a float (0.0–100.0), or `nil` if no completed matches.
  """
  @spec win_rate(non_neg_integer(), non_neg_integer()) :: float() | nil
  def win_rate(wins, losses) do
    total = wins + losses
    if total == 0, do: nil, else: Float.round(wins / total * 100, 1)
  end

  @doc """
  Returns the opponent's rank string from the most recent match in the history,
  or `nil` if the history is empty or no match carries a rank.
  """
  @spec latest_rank(list()) :: String.t() | nil
  def latest_rank([]), do: nil

  def latest_rank(history) do
    history
    |> Enum.max_by(& &1.started_at, DateTime)
    |> Map.get(:opponent_rank)
  end

  @doc """
  Builds the JSON-encoded cumulative win rate series for the `Chart` hook.

  Accepts matches in any order; sorts ascending by `started_at` before
  computing. Excludes matches with `nil` won. Returns `"[]"` if fewer than 3
  matches are present — the panel suppresses the chart at that threshold.
  """
  @spec chart_series(list()) :: String.t()
  def chart_series(history) when length(history) < 3, do: "[]"

  def chart_series(history) do
    history
    |> Enum.sort_by(& &1.started_at, DateTime)
    |> Enum.filter(&(not is_nil(&1.won)))
    |> Enum.reduce({0, 0, []}, fn match, {wins, total, acc} ->
      wins = if match.won, do: wins + 1, else: wins
      total = total + 1
      rate = Float.round(wins / total * 100, 1)

      point = %{
        timestamp: DateTime.to_iso8601(match.started_at),
        win_rate: rate,
        wins: wins,
        total: total
      }

      {wins, total, [point | acc]}
    end)
    |> elem(2)
    |> Enum.reverse()
    |> LiveHelpers.cumulative_winrate_series()
  end
end
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
mix test test/scry_2_web/live/opponent_helpers_test.exs
```

Expected: all tests green, no warnings.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat: add OpponentHelpers with record, win_rate, latest_rank, chart_series"
jj new
```

---

## Task 2: OpponentComponents — the panel component

**Files:**
- Create: `lib/scry_2_web/components/opponent_components.ex`
- Modify: `lib/scry_2_web.ex` (add import to `html_helpers/0`)

- [ ] **Step 1: Create the component module**

Create `lib/scry_2_web/components/opponent_components.ex`:

```elixir
defmodule Scry2Web.OpponentComponents do
  @moduledoc """
  Reusable function components for opponent summary panels.

  Provides `<.opponent_panel>`, a self-contained section showing the
  overall record, win rate, optional cumulative win rate chart, and
  match history against a specific opponent.

  ## Usage

      <.opponent_panel
        id="match-opponent"
        opponent={@match.opponent_screen_name}
        history={@opponent_history}
      />

  The `history` list is all previous matches against the opponent (fetched
  by the LiveView via `Matches.opponent_matches/2`). Pass an empty list for
  first-time opponents — the component handles the empty state gracefully.
  """

  use Phoenix.Component

  import Scry2Web.CoreComponents
  import Scry2Web.LiveHelpers

  alias Scry2Web.MatchesHelpers
  alias Scry2Web.OpponentHelpers

  use Scry2Web, :verified_routes

  @doc """
  Renders an opponent history panel: header, stats row, optional chart,
  and a list of prior matches.
  """
  attr :id, :string, required: true
  attr :opponent, :string, required: true
  attr :history, :list, required: true

  def opponent_panel(assigns) do
    {wins, losses} = OpponentHelpers.record(assigns.history)

    assigns =
      assign(assigns,
        wins: wins,
        losses: losses,
        win_rate: OpponentHelpers.win_rate(wins, losses),
        latest_rank: OpponentHelpers.latest_rank(assigns.history)
      )

    ~H"""
    <section class="mb-8">
      <h2 class="text-lg font-semibold mb-4 font-beleren flex items-center gap-2">
        vs {@opponent}
        <.rank_icon :if={@latest_rank} rank={@latest_rank} />
      </h2>

      <p :if={@history == []} class="text-sm text-base-content/50">
        First time playing this opponent.
      </p>

      <div :if={@history != []}>
        <div class="grid grid-cols-2 gap-3 mb-4">
          <.stat_card title="Record" value={record_str(@wins, @losses)} />
          <.stat_card
            title="Win Rate"
            value={format_win_rate(@win_rate)}
            class={win_rate_class(@win_rate)}
          />
        </div>

        <div
          :if={length(@history) > 2}
          id={"#{@id}-chart"}
          phx-hook="Chart"
          data-chart-type="cumulative_winrate"
          data-series={OpponentHelpers.chart_series(@history)}
          class="min-h-[10rem] rounded-lg bg-base-300/40 mb-4"
        />

        <div class="flex flex-col divide-y divide-base-content/5">
          <.link
            :for={prev <- @history}
            navigate={~p"/matches/#{prev.id}"}
            class="flex items-center gap-4 py-2 hover:bg-base-content/3 rounded px-2 -mx-2 transition-colors"
          >
            <span class={[
              "font-bold w-6 text-center",
              MatchesHelpers.result_letter_class(prev.won)
            ]}>
              {MatchesHelpers.result_letter(prev.won)}
            </span>
            <span class="text-sm text-base-content/60 inline-flex items-center gap-1">
              <.set_icon :if={prev.set_code} code={prev.set_code} />
              {format_label(prev.format)}
            </span>
            <span class="text-xs text-base-content/40 tabular-nums">
              {MatchesHelpers.format_match_datetime(prev.started_at)}
            </span>
          </.link>
        </div>
      </div>
    </section>
    """
  end
end
```

- [ ] **Step 2: Register it in `html_helpers/0` so it's available in all LiveViews**

In `lib/scry_2_web.ex`, find the `defp html_helpers do` block. After the existing `import Scry2Web.CardComponents` line, add the new import:

Old:
```elixir
      # Core UI components
      import Scry2Web.CoreComponents
      import Scry2Web.CardComponents
```

New:
```elixir
      # Core UI components
      import Scry2Web.CoreComponents
      import Scry2Web.CardComponents
      import Scry2Web.OpponentComponents
```

- [ ] **Step 3: Verify compilation is clean**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warnings-as-errors
```

Expected: compiles with zero warnings.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat: add OpponentComponents with <.opponent_panel>"
jj new
```

---

## Task 3: Wire into MatchesLive

**Files:**
- Modify: `lib/scry_2_web/live/matches_live.ex`

- [ ] **Step 1: Replace the call site**

Find this block (around line 245–250):

```heex
      <%!-- Opponent history --%>
      <.opponent_history
        :if={@match.opponent_screen_name}
        opponent={@match.opponent_screen_name}
        history={@opponent_history}
      />
```

Replace with:

```heex
      <%!-- Opponent history --%>
      <.opponent_panel
        :if={@match.opponent_screen_name}
        id="match-opponent"
        opponent={@match.opponent_screen_name}
        history={@opponent_history}
      />
```

- [ ] **Step 2: Remove the private `opponent_history/1` defp**

Find and delete the entire private function (lines ~679–716):

```elixir
  defp opponent_history(assigns) do
    wins = Enum.count(assigns.history, & &1.won)
    losses = Enum.count(assigns.history, &(&1.won == false))

    assigns = assign(assigns, wins: wins, losses: losses)

    ~H"""
    <section class="mb-8">
      ...
    </section>
    """
  end
```

Delete that entire `defp opponent_history` block (from the `defp` line through the closing `end`).

- [ ] **Step 3: Run the full test suite and precommit**

```bash
mix precommit
```

Expected: zero warnings, zero failures.

- [ ] **Step 4: Commit**

```bash
jj describe -m "refactor: replace inline opponent_history with reusable <.opponent_panel>"
jj new
```

---

## Verification

1. Start the dev server: `mix phx.server`
2. Navigate to any match detail page that has previous matches against the same opponent (`http://localhost:4444/matches/:id`)
3. Scroll to the bottom — the panel should show:
   - "vs [Name]" header with rank icon (if the opponent has a rank in the history)
   - Record stat card ("2W–1L" or similar) and Win Rate stat card ("66.7%")
   - A cumulative win rate chart if there are more than 2 prior matches
   - The match list below the chart
4. Navigate to a match with a first-time opponent — should show only "First time playing this opponent."
5. Check the browser console for any JavaScript errors from the Chart hook.
