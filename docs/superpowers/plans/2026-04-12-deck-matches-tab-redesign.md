# Deck Matches Tab Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the deck detail matches tab for fast scanning — BO1/BO3 format switcher, date-grouped rows, per-game detail lines with mulligans, humanized event names, rank icons, and pagination.

**Architecture:** The projection layer (`DeckProjection`) gets enriched with `num_mulligans` per game. The context (`Decks`) gains paginated, format-filtered queries. The LiveView (`DecksLive`) gets a format switcher with URL-driven state, date-grouped rendering, and format-specific table layouts. Pure display helpers go in `DecksHelpers`.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto (SQLite), daisyUI/Tailwind

---

### Task 1: Enrich DeckProjection with per-game mulligan counts

**Files:**
- Modify: `lib/scry_2/decks/deck_projection.ex:214-219`
- Test: `test/scry_2/decks/deck_projection_test.exs`

The `GameCompleted` event already carries `num_mulligans`. The deck projection currently builds game result maps without it. Add it.

- [ ] **Step 1: Write the failing test**

In `test/scry_2/decks/deck_projection_test.exs`, add a test that verifies `num_mulligans` is stored in `game_results`:

```elixir
test "game_completed stores num_mulligans in game_results" do
  # Set up: create a deck submission and match result, then project a GameCompleted
  deck_id = "test-deck-#{System.unique_integer([:positive])}"
  match_id = "test-match-#{System.unique_integer([:positive])}"

  Decks.upsert_deck!(%{mtga_deck_id: deck_id, current_name: "Test Deck"})

  Decks.upsert_match_result!(%{
    mtga_deck_id: deck_id,
    mtga_match_id: match_id
  })

  event = %Scry2.Events.Match.GameCompleted{
    mtga_match_id: match_id,
    game_number: 1,
    won: true,
    on_play: true,
    num_mulligans: 2,
    occurred_at: DateTime.utc_now()
  }

  # Invoke projection directly
  send(Scry2.Decks.DeckProjection, {:domain_event, 999, "game_completed", event})
  # Give the GenServer time to process
  :timer.sleep(50)

  result = Scry2.Repo.get_by(Scry2.Decks.MatchResult,
    mtga_deck_id: deck_id,
    mtga_match_id: match_id
  )

  game1 = Enum.find(result.game_results["results"], &(&1["game"] == 1))
  assert game1["num_mulligans"] == 2
end
```

Note: Check how existing projection tests work in this file — follow the same pattern for invoking the projector. The above is a starting template; adapt to match the existing test setup patterns.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/scry_2/decks/deck_projection_test.exs --trace`
Expected: FAIL — `num_mulligans` key not present in game result map

- [ ] **Step 3: Add num_mulligans to the game result map**

In `lib/scry_2/decks/deck_projection.ex`, modify the `project(%GameCompleted{})` function. Change lines 214-218:

```elixir
        new_result = %{
          "game" => event.game_number,
          "won" => event.won,
          "on_play" => event.on_play
        }
```

To:

```elixir
        new_result = %{
          "game" => event.game_number,
          "won" => event.won,
          "on_play" => event.on_play,
          "num_mulligans" => event.num_mulligans || 0
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/scry_2/decks/deck_projection_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: store per-game mulligan counts in deck match projection"
```

---

### Task 2: Add paginated format-filtered query to Decks context

**Files:**
- Modify: `lib/scry_2/decks.ex:215-220`
- Test: `test/scry_2/decks_test.exs`

Replace the current `list_matches_for_deck/1` with a paginated, format-filtered version that returns `{matches, total_count}`.

- [ ] **Step 1: Write the failing test**

```elixir
describe "list_matches_for_deck/2" do
  test "paginates matches" do
    deck_id = "paginate-test-#{System.unique_integer([:positive])}"
    Decks.upsert_deck!(%{mtga_deck_id: deck_id, current_name: "Test"})

    # Create 3 matches
    for i <- 1..3 do
      Decks.upsert_match_result!(%{
        mtga_deck_id: deck_id,
        mtga_match_id: "match-#{i}",
        won: true,
        started_at: DateTime.add(DateTime.utc_now(), -i, :hour)
      })
    end

    {matches, total} = Decks.list_matches_for_deck(deck_id, limit: 2, offset: 0)
    assert length(matches) == 2
    assert total == 3

    {page2, _} = Decks.list_matches_for_deck(deck_id, limit: 2, offset: 2)
    assert length(page2) == 1
  end

  test "filters by format — bo3" do
    deck_id = "format-test-#{System.unique_integer([:positive])}"
    Decks.upsert_deck!(%{mtga_deck_id: deck_id, current_name: "Test"})

    Decks.upsert_match_result!(%{
      mtga_deck_id: deck_id,
      mtga_match_id: "bo3-match",
      won: true,
      format_type: "Traditional",
      started_at: DateTime.utc_now()
    })

    Decks.upsert_match_result!(%{
      mtga_deck_id: deck_id,
      mtga_match_id: "bo1-match",
      won: true,
      format_type: "Constructed",
      num_games: 1,
      started_at: DateTime.utc_now()
    })

    {bo3, bo3_total} = Decks.list_matches_for_deck(deck_id, format: :bo3)
    assert bo3_total == 1
    assert hd(bo3).format_type == "Traditional"

    {bo1, bo1_total} = Decks.list_matches_for_deck(deck_id, format: :bo1)
    assert bo1_total == 1
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/scry_2/decks_test.exs --trace`
Expected: FAIL — function clause error or wrong return shape

- [ ] **Step 3: Implement paginated list_matches_for_deck/2**

Replace the existing `list_matches_for_deck/1` in `lib/scry_2/decks.ex` (lines 215-220):

```elixir
@doc """
Returns completed match results for a deck, newest first, with pagination
and optional format filter.

Options:
  * `:limit` — max results per page (default 20)
  * `:offset` — pagination offset (default 0)
  * `:format` — `:bo1` or `:bo3` (default: all)

Returns `{matches, total_count}`.
"""
def list_matches_for_deck(mtga_deck_id, opts \\ []) when is_binary(mtga_deck_id) do
  limit = Keyword.get(opts, :limit, 20)
  offset = Keyword.get(opts, :offset, 0)
  format = Keyword.get(opts, :format)

  base =
    MatchResult
    |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
    |> apply_format_filter(format)

  total = Repo.aggregate(base, :count)

  matches =
    base
    |> order_by([mr], desc: mr.started_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()

  {matches, total}
end

defp apply_format_filter(query, :bo3) do
  where(query, [mr], mr.format_type == "Traditional" or mr.num_games > 1)
end

defp apply_format_filter(query, :bo1) do
  where(query, [mr],
    (is_nil(mr.format_type) or mr.format_type != "Traditional") and
      (is_nil(mr.num_games) or mr.num_games <= 1)
  )
end

defp apply_format_filter(query, _), do: query
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/scry_2/decks_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Add helper to find most recently played format**

Add this function to `lib/scry_2/decks.ex`:

```elixir
@doc """
Returns the format (`:bo1` or `:bo3`) that was most recently played for a deck.
Returns `:bo3` if no matches exist.
"""
def most_recent_format(mtga_deck_id) when is_binary(mtga_deck_id) do
  latest =
    MatchResult
    |> where([mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))
    |> order_by([mr], desc: mr.started_at)
    |> limit(1)
    |> Repo.one()

  case latest do
    nil -> :bo3
    match -> if bo3?(match), do: :bo3, else: :bo1
  end
end
```

- [ ] **Step 6: Add helper to check if a deck has matches in a given format**

```elixir
@doc """
Returns `%{bo1: count, bo3: count}` for a deck — used to determine
which format tabs should be enabled.
"""
def match_counts_by_format(mtga_deck_id) when is_binary(mtga_deck_id) do
  {_, bo1_count} = list_matches_for_deck(mtga_deck_id, format: :bo1, limit: 0)
  {_, bo3_count} = list_matches_for_deck(mtga_deck_id, format: :bo3, limit: 0)
  %{bo1: bo1_count, bo3: bo3_count}
end
```

Note: `limit: 0` won't actually work for fetching counts efficiently. Instead, use the aggregate query directly:

```elixir
def match_counts_by_format(mtga_deck_id) when is_binary(mtga_deck_id) do
  base = where(MatchResult, [mr], mr.mtga_deck_id == ^mtga_deck_id and not is_nil(mr.won))

  bo3_count = base |> apply_format_filter(:bo3) |> Repo.aggregate(:count)
  bo1_count = base |> apply_format_filter(:bo1) |> Repo.aggregate(:count)

  %{bo1: bo1_count, bo3: bo3_count}
end
```

- [ ] **Step 7: Run full test suite and commit**

Run: `mix test --trace`
Expected: PASS (check that callers of the old `list_matches_for_deck/1` still work — the overview tab in `get_deck_performance` doesn't call it, so no breakage expected; `load_deck_detail` does call it and will need updating in Task 4)

```bash
jj desc -m "feat: add paginated format-filtered match queries for deck context"
```

---

### Task 3: Add display helpers for date grouping and event humanization

**Files:**
- Modify: `lib/scry_2_web/live/decks_helpers.ex`
- Test: `test/scry_2_web/live/decks_helpers_test.exs`

Pure functions — no database, `async: true`.

- [ ] **Step 1: Write tests for date grouping**

```elixir
describe "group_matches_by_date/1" do
  test "groups matches under date labels" do
    today = DateTime.utc_now()
    yesterday = DateTime.add(today, -1, :day)
    older = ~U[2026-04-05 12:00:00Z]

    matches = [
      %{started_at: today, id: 1},
      %{started_at: today |> DateTime.add(-1, :hour), id: 2},
      %{started_at: yesterday, id: 3},
      %{started_at: older, id: 4}
    ]

    groups = DecksHelpers.group_matches_by_date(matches)
    assert length(groups) == 3

    [{label1, m1}, {label2, m2}, {label3, m3}] = groups
    assert label1 == "Today"
    assert length(m1) == 2
    assert label2 == "Yesterday"
    assert length(m2) == 1
    assert String.contains?(label3, "April")
    assert length(m3) == 1
  end

  test "handles empty list" do
    assert DecksHelpers.group_matches_by_date([]) == []
  end
end
```

- [ ] **Step 2: Write tests for event humanization**

```elixir
describe "humanize_event/2" do
  test "Traditional_Ladder with Standard format" do
    assert DecksHelpers.humanize_event("Traditional_Ladder", "Standard") == "Ranked Standard"
  end

  test "Ladder with Standard format" do
    assert DecksHelpers.humanize_event("Ladder", "Standard") == "Ranked Standard"
  end

  test "DirectGame" do
    assert DecksHelpers.humanize_event("DirectGame", "Standard") == "Direct Challenge"
  end

  test "nil event_name" do
    assert DecksHelpers.humanize_event(nil, "Standard") == "—"
  end

  test "draft event uses format_event_name" do
    result = DecksHelpers.humanize_event("QuickDraft_FDN_20260323", nil)
    assert result == "Quick Draft"
  end
end
```

- [ ] **Step 3: Write test for game_lines helper**

```elixir
describe "format_game_results/1" do
  test "returns per-game details from game_results map" do
    game_results = %{
      "results" => [
        %{"game" => 1, "won" => true, "on_play" => true, "num_mulligans" => 0},
        %{"game" => 2, "won" => false, "on_play" => false, "num_mulligans" => 1},
        %{"game" => 3, "won" => true, "on_play" => true, "num_mulligans" => 2}
      ]
    }

    games = DecksHelpers.format_game_results(game_results)
    assert length(games) == 3

    [g1, g2, g3] = games
    assert g1 == %{won: true, on_play: true, num_mulligans: 0}
    assert g2 == %{won: false, on_play: false, num_mulligans: 1}
    assert g3 == %{won: true, on_play: true, num_mulligans: 2}
  end

  test "handles nil game_results" do
    assert DecksHelpers.format_game_results(nil) == []
  end
end
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mix test test/scry_2_web/live/decks_helpers_test.exs --trace`
Expected: FAIL — functions don't exist

- [ ] **Step 5: Implement group_matches_by_date/1**

Add to `lib/scry_2_web/live/decks_helpers.ex`:

```elixir
@doc """
Groups a chronologically-sorted list of matches under date labels.
Returns `[{label, [match, ...]}]` where label is "Today", "Yesterday",
or a formatted date like "April 10".
"""
@spec group_matches_by_date(list()) :: [{String.t(), list()}]
def group_matches_by_date([]), do: []

def group_matches_by_date(matches) do
  today = Date.utc_today()
  yesterday = Date.add(today, -1)

  matches
  |> Enum.group_by(fn match ->
    case match.started_at do
      nil -> "Unknown"
      dt -> date_label(DateTime.to_date(dt), today, yesterday)
    end
  end)
  |> Enum.sort_by(fn {_label, [first | _]} -> first.started_at end, {:desc, DateTime})
end

defp date_label(date, today, _yesterday) when date == today, do: "Today"
defp date_label(date, _today, yesterday) when date == yesterday, do: "Yesterday"

defp date_label(date, _today, _yesterday) do
  "#{month_name(date.month)} #{date.day}"
end
```

- [ ] **Step 6: Implement humanize_event/2**

```elixir
@doc """
Converts an MTGA event name to a human-readable label.
Combines the inferred event format with the deck's format when applicable.
"""
@spec humanize_event(String.t() | nil, String.t() | nil) :: String.t()
def humanize_event(nil, _deck_format), do: "—"

def humanize_event(event_name, deck_format) do
  case Scry2.Events.EnrichEvents.infer_format(event_name) do
    {"Ranked", _} -> "Ranked #{deck_format || "Constructed"}"
    {"Ranked BO3", _} -> "Ranked #{deck_format || "Constructed"}"
    {"Play", _} -> "Play #{deck_format || "Constructed"}"
    {"Play BO3", _} -> "Play BO3 #{deck_format || "Constructed"}"
    {"Direct Challenge", _} -> "Direct Challenge"
    {format, "Limited"} -> format
    {format, _} -> format
  end
end
```

- [ ] **Step 7: Implement format_game_results/1**

```elixir
@doc """
Extracts per-game details from a match's game_results map.
Returns a list of `%{won, on_play, num_mulligans}` sorted by game number.
"""
@spec format_game_results(map() | nil) :: [%{won: boolean(), on_play: boolean(), num_mulligans: non_neg_integer()}]
def format_game_results(nil), do: []
def format_game_results(%{"results" => results}) when is_list(results) do
  results
  |> Enum.sort_by(& &1["game"])
  |> Enum.map(fn game ->
    %{
      won: game["won"],
      on_play: game["on_play"],
      num_mulligans: game["num_mulligans"] || 0
    }
  end)
end
def format_game_results(_), do: []
```

- [ ] **Step 8: Also add match_score/1 helper**

```elixir
@doc """
Returns a match score string like '2–1' from game_results.
Returns nil for BO1 (single game matches).
"""
@spec match_score(map() | nil) :: String.t() | nil
def match_score(nil), do: nil

def match_score(%{"results" => results}) when is_list(results) and length(results) > 1 do
  wins = Enum.count(results, & &1["won"])
  losses = length(results) - wins
  "#{wins}–#{losses}"
end

def match_score(_), do: nil
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `mix test test/scry_2_web/live/decks_helpers_test.exs --trace`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
jj desc -m "feat: add date grouping, event humanization, and game result helpers"
```

---

### Task 4: Rewrite the matches tab LiveView with format switcher and new layout

**Files:**
- Modify: `lib/scry_2_web/live/decks_live.ex`

This is the main UI task. Changes to `handle_params`, `load_deck_detail`, and the `matches_tab` component.

- [ ] **Step 1: Update handle_params to parse format and page params**

In `lib/scry_2_web/live/decks_live.ex`, update the `handle_params` clause for deck detail (line 43) to parse `format` and `page`:

```elixir
@impl true
def handle_params(%{"deck_id" => deck_id} = params, _uri, socket) do
  deck = Decks.get_deck(deck_id)

  if is_nil(deck) do
    {:noreply, push_navigate(socket, to: ~p"/decks")}
  else
    tab = parse_tab(params["tab"])
    format = parse_format(params["format"])
    page = parse_page(params["page"])
    socket = load_deck_detail(socket, deck, tab, format, page)
    {:noreply, socket}
  end
end
```

Add the parsers at the bottom:

```elixir
defp parse_format("bo1"), do: :bo1
defp parse_format("bo3"), do: :bo3
defp parse_format(_), do: nil

defp parse_page(nil), do: 1
defp parse_page(p) when is_binary(p) do
  case Integer.parse(p) do
    {n, _} when n > 0 -> n
    _ -> 1
  end
end
```

- [ ] **Step 2: Update load_deck_detail to pass format/page**

Replace the matches loading in `load_deck_detail` (lines 866-898):

```elixir
defp load_deck_detail(socket, deck, tab, format \\ nil, page \\ 1) do
  performance = Decks.get_deck_performance(deck.mtga_deck_id)
  match_count = performance.bo1.total + performance.bo3.total
  version_count = Decks.count_versions(deck.mtga_deck_id)

  {matches, matches_total, format_counts, active_format} =
    if tab == :matches do
      counts = Decks.match_counts_by_format(deck.mtga_deck_id)

      active_format =
        format || Decks.most_recent_format(deck.mtga_deck_id)

      offset = (page - 1) * 20
      {matches, total} = Decks.list_matches_for_deck(deck.mtga_deck_id,
        format: active_format, limit: 20, offset: offset)

      {matches, total, counts, active_format}
    else
      {[], 0, %{bo1: 0, bo3: 0}, nil}
    end

  {versions, version_matches} =
    if tab == :changes do
      {Decks.get_deck_versions(deck.mtga_deck_id),
       Decks.get_matches_by_version(deck.mtga_deck_id)}
    else
      {[], %{}}
    end

  arena_ids = collect_arena_ids(deck, versions)
  cards_by_arena_id = Cards.list_by_arena_ids(arena_ids)

  if connected?(socket) do
    ImageCache.ensure_cached(arena_ids)
  end

  total_pages = max(1, ceil(matches_total / 20))

  assign(socket,
    deck: deck,
    performance: performance,
    match_count: match_count,
    version_count: version_count,
    versions: versions,
    version_matches: version_matches,
    matches: matches,
    matches_total: matches_total,
    matches_page: page,
    matches_total_pages: total_pages,
    format_counts: format_counts,
    active_format: active_format,
    cards_by_arena_id: cards_by_arena_id,
    active_tab: tab
  )
end
```

Update `mount/3` to include the new assigns with defaults:

```elixir
matches_total: 0,
matches_page: 1,
matches_total_pages: 1,
format_counts: %{bo1: 0, bo3: 0},
active_format: nil,
```

- [ ] **Step 3: Update the handle_info reload to pass format/page**

Update `handle_info(:reload_data, ...)` to preserve format and page:

```elixir
socket
|> load_deck_detail(fresh_deck, socket.assigns.active_tab,
   socket.assigns.active_format, socket.assigns.matches_page)
|> assign(reload_timer: nil)
```

- [ ] **Step 4: Update the matches_tab call in render to pass new assigns**

In the `render/1` function (around line 228), update:

```elixir
<% :matches -> %>
  <.matches_tab
    matches={@matches}
    matches_total={@matches_total}
    matches_page={@matches_page}
    matches_total_pages={@matches_total_pages}
    format_counts={@format_counts}
    active_format={@active_format}
    deck={@deck}
  />
```

- [ ] **Step 5: Rewrite the matches_tab component**

Replace the entire `matches_tab` component (lines 538-591):

```elixir
attr :matches, :list, required: true
attr :matches_total, :integer, required: true
attr :matches_page, :integer, required: true
attr :matches_total_pages, :integer, required: true
attr :format_counts, :map, required: true
attr :active_format, :atom, required: true
attr :deck, :map, required: true

defp matches_tab(assigns) do
  grouped = DecksHelpers.group_matches_by_date(assigns.matches)
  assigns = assign(assigns, :grouped_matches, grouped)

  ~H"""
  <%!-- Format switcher --%>
  <div class="flex items-center gap-2 mb-4">
    <div class="inline-flex bg-base-300 rounded-lg p-0.5 gap-0.5">
      <.format_switch_btn
        label="BO3"
        format={:bo3}
        active={@active_format}
        count={@format_counts.bo3}
        deck={@deck}
      />
      <.format_switch_btn
        label="BO1"
        format={:bo1}
        active={@active_format}
        count={@format_counts.bo1}
        deck={@deck}
      />
    </div>
  </div>

  <%!-- Empty state --%>
  <.empty_state :if={@matches == []}>
    No {@active_format |> Atom.to_string() |> String.upcase()} matches recorded for this deck yet.
  </.empty_state>

  <%!-- Match table --%>
  <div :if={@matches != []} class="overflow-x-auto">
    <table class="table w-full">
      <thead>
        <tr class="text-xs text-base-content/60 uppercase">
          <th>Result</th>
          <th>{if @active_format == :bo3, do: "Games", else: "Play / Draw"}</th>
          <th>Event</th>
          <th>Rank</th>
        </tr>
      </thead>
      <tbody>
        <%= for {date_label, matches} <- @grouped_matches do %>
          <tr>
            <td colspan="4" class="text-sm text-base-content/50 font-medium pt-4 pb-1 border-b-0">
              {date_label}
            </td>
          </tr>
          <%= for match <- matches do %>
            <.match_row match={match} format={@active_format} deck={@deck} />
          <% end %>
        <% end %>
      </tbody>
    </table>

    <%!-- Pagination --%>
    <.matches_pagination
      :if={@matches_total_pages > 1}
      page={@matches_page}
      total_pages={@matches_total_pages}
      total={@matches_total}
      format={@active_format}
      deck={@deck}
    />
  </div>
  """
end
```

- [ ] **Step 6: Add the format_switch_btn component**

```elixir
attr :label, :string, required: true
attr :format, :atom, required: true
attr :active, :atom, required: true
attr :count, :integer, required: true
attr :deck, :map, required: true

defp format_switch_btn(%{count: 0, format: format, active: active} = assigns)
     when format != active do
  ~H"""
  <span class="px-4 py-1.5 rounded-md text-sm font-medium text-base-content/30 cursor-not-allowed">
    {@label}
  </span>
  """
end

defp format_switch_btn(assigns) do
  ~H"""
  <.link
    patch={~p"/decks/#{@deck.mtga_deck_id}?tab=matches&format=#{@format}"}
    class={[
      "px-4 py-1.5 rounded-md text-sm font-medium transition-colors",
      if(@active == @format,
        do: "bg-base-100 text-base-content shadow-sm",
        else: "text-base-content/60 hover:text-base-content"
      )
    ]}
  >
    {@label}
  </.link>
  """
end
```

- [ ] **Step 7: Add the match_row component — BO3 variant**

```elixir
attr :match, :map, required: true
attr :format, :atom, required: true
attr :deck, :map, required: true

defp match_row(%{format: :bo3} = assigns) do
  game_results = DecksHelpers.format_game_results(assigns.match.game_results)
  score = DecksHelpers.match_score(assigns.match.game_results)

  assigns = assign(assigns, game_results: game_results, score: score)

  ~H"""
  <tr class="hover:bg-base-content/5">
    <td class="align-top">
      <span class={if @match.won, do: "text-success font-semibold", else: "text-error font-semibold"}>
        {if @match.won, do: "Win", else: "Loss"}
      </span>
      <span :if={@score} class="text-sm text-base-content/50 ml-1">{@score}</span>
    </td>
    <td class="align-top">
      <div class="flex flex-col gap-0.5">
        <div :for={game <- @game_results} class="text-sm flex items-center gap-1.5">
          <span class={if game.won, do: "text-success font-semibold", else: "text-error font-semibold"}>
            {if game.won, do: "W", else: "L"}
          </span>
          <span class={if game.on_play, do: "text-info", else: "text-base-content/70"}>
            {if game.on_play, do: "play", else: "draw"}
          </span>
          <span :if={game.num_mulligans > 0} class="text-base-content/40 text-xs">
            · mull ×{game.num_mulligans}
          </span>
        </div>
      </div>
    </td>
    <td class="text-sm text-base-content/70 align-top">
      {DecksHelpers.humanize_event(@match.event_name, @deck.format)}
    </td>
    <td class="align-top">
      <span :if={@match.player_rank} class="inline-flex items-center gap-1.5 text-sm text-base-content/70">
        <.rank_icon rank={@match.player_rank} format_type={@match.format_type || "Constructed"} class="h-4" />
        {@match.player_rank}
      </span>
      <span :if={is_nil(@match.player_rank)} class="text-sm text-base-content/40">—</span>
    </td>
  </tr>
  """
end
```

- [ ] **Step 8: Add the match_row component — BO1 variant**

```elixir
defp match_row(%{format: :bo1} = assigns) do
  game_results = DecksHelpers.format_game_results(assigns.match.game_results)
  game = List.first(game_results)
  assigns = assign(assigns, :game, game)

  ~H"""
  <tr class="hover:bg-base-content/5">
    <td>
      <span class={if @match.won, do: "text-success font-semibold", else: "text-error font-semibold"}>
        {if @match.won, do: "Win", else: "Loss"}
      </span>
    </td>
    <td class="text-sm">
      <%= if @game do %>
        <span class={if @game.on_play, do: "text-info", else: "text-base-content/70"}>
          {if @game.on_play, do: "play", else: "draw"}
        </span>
        <span :if={@game.num_mulligans > 0} class="text-base-content/40 text-xs">
          · mull ×{@game.num_mulligans}
        </span>
      <% else %>
        <span class={if @match.on_play, do: "text-info", else: "text-base-content/70"}>
          {case @match.on_play do
            true -> "play"
            false -> "draw"
            nil -> "—"
          end}
        </span>
      <% end %>
    </td>
    <td class="text-sm text-base-content/70">
      {DecksHelpers.humanize_event(@match.event_name, @deck.format)}
    </td>
    <td>
      <span :if={@match.player_rank} class="inline-flex items-center gap-1.5 text-sm text-base-content/70">
        <.rank_icon rank={@match.player_rank} format_type={@match.format_type || "Constructed"} class="h-4" />
        {@match.player_rank}
      </span>
      <span :if={is_nil(@match.player_rank)} class="text-sm text-base-content/40">—</span>
    </td>
  </tr>
  """
end
```

- [ ] **Step 9: Add the pagination component**

```elixir
attr :page, :integer, required: true
attr :total_pages, :integer, required: true
attr :total, :integer, required: true
attr :format, :atom, required: true
attr :deck, :map, required: true

defp matches_pagination(assigns) do
  start_item = (assigns.page - 1) * 20 + 1
  end_item = min(assigns.page * 20, assigns.total)
  assigns = assign(assigns, start_item: start_item, end_item: end_item)

  ~H"""
  <div class="flex items-center justify-between px-2 py-3 text-sm">
    <span class="text-base-content/50 text-xs">
      Showing {@start_item}–{@end_item} of {@total} matches
    </span>
    <div class="flex gap-1">
      <.link
        :for={p <- 1..@total_pages}
        patch={~p"/decks/#{@deck.mtga_deck_id}?tab=matches&format=#{@format}&page=#{p}"}
        class={[
          "px-2.5 py-1 rounded text-xs border",
          if(p == @page,
            do: "bg-base-300 text-base-content border-base-content/20",
            else: "border-base-300 text-base-content/50 hover:border-base-content/30"
          )
        ]}
      >
        {p}
      </.link>
    </div>
  </div>
  """
end
```

- [ ] **Step 10: Run precommit and fix any issues**

Run: `mix precommit`
Expected: PASS — no warnings, all tests pass, properly formatted

- [ ] **Step 11: Commit**

```bash
jj desc -m "feat: redesign deck matches tab with format switcher, date groups, game lines, and pagination"
```

---

### Task 5: Visual verification and polish

**Files:** None new — verification only.

- [ ] **Step 1: Replay projections to backfill mulligan data**

Use tidewave to run:
```elixir
Scry2.Events.replay_projections!()
```

- [ ] **Step 2: Verify BO3 view in browser**

Navigate to `http://localhost:4444/decks/<deck_id>?tab=matches&format=bo3`. Verify:
- Format switcher shows BO3 active
- Date headers group matches correctly ("Today", "Yesterday", date)
- Each match shows "Win 2–1" or "Loss 0–2" with correct score
- Game lines show W/L (colored), play/draw, and mull ×N when applicable
- Event names are humanized ("Ranked Standard" not "Traditional_Ladder")
- Rank icons display next to rank text
- Pagination appears when > 20 matches

- [ ] **Step 3: Verify BO1 view**

Navigate with `?tab=matches&format=bo1`. Verify:
- Simplified columns: Result, Play/Draw, Event, Rank
- No Games column
- Play/draw and mulligans inline

- [ ] **Step 4: Verify format switcher behavior**

- URL updates when switching formats
- Default selection is most recently played format
- Disabled format is greyed and non-clickable when no matches exist
- Page resets to 1 when switching formats (no stale page param)

- [ ] **Step 5: Verify empty state**

If a deck has only BO3 matches, switch to BO1 — verify the empty state message displays correctly.

- [ ] **Step 6: Verify pagination**

Click through pages, verify URL updates, correct items shown.

- [ ] **Step 7: Check tidewave logs for runtime errors**

Use `mcp__tidewave__get_logs(level: "error")` to check for any errors during page loads.

- [ ] **Step 8: Run full precommit**

Run: `mix precommit`
Expected: Clean pass — zero warnings, all tests pass

- [ ] **Step 9: Final commit if any polish was needed**

```bash
jj desc -m "fix: polish deck matches tab after visual review"
```
