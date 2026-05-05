defmodule Scry2Web.PageSmokeTest do
  @moduledoc """
  Visits every routable LiveView page and asserts it mounts and renders
  within a strict time budget. Pattern mirrors media-centarr's
  `page_smoke_test.exs` — the cheapest possible safety net for the kind
  of bug where adding a new assign or template variable trips a
  `KeyError` only on a specific page, or where a slow query creeps into
  a mount path.

  Each page (and each detail route that needs a seeded record) gets one
  test. If a page needs additional setup to mount (a player must be
  active, a match/deck/draft must exist) the setup happens in this
  file so the smoke test stays isolated from per-page test files.

  Budget: 50ms locally, 150ms on CI (jitter headroom on shared runners).
  """

  use Scry2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Scry2.Settings
  alias Scry2.SetupFlow
  alias Scry2.TestFactory

  # Aggressive mount-time budget. Scry2 is a local-first app; mounts
  # should be near-instant. Steady-state mounts cluster at 6–27ms;
  # 50ms catches real regressions without flapping. CI runners are
  # noisier, so the budget loosens to 150ms there. Do not loosen
  # casually.
  @render_budget_local_ms 50
  @render_budget_ci_ms 150

  # Cold-start cost (BEAM JIT, schema cache, first-DB-query overhead) is
  # paid by whichever mount runs first. Without a warmup, that test
  # becomes flaky as the budget tightens. We pay it once per `mix test`
  # invocation and gate further runs with :persistent_term so subsequent
  # tests measure steady-state only.
  @warmup_flag {__MODULE__, :warmed_up?}

  # Mirror of media-centarr's smoke setup: only the warmup runs per test.
  # Index-page tests render fine with no active player (all-players view), so
  # we don't pay for player creation + Settings write on every mount. Detail
  # routes that *need* an active player seed it in their own describe block.
  setup %{conn: conn} = context do
    warmup_once(conn)
    context
  end

  defp seed_active_player do
    player = TestFactory.create_player(%{screen_name: "SmokeTester"})
    Settings.put!("active_player_id", player.id)
    player
  end

  for {path, label} <- [
        {"/", "health"},
        {"/player", "player"},
        {"/ranks", "ranks"},
        {"/economy", "economy"},
        {"/match-economy", "match economy"},
        {"/collection", "collection"},
        {"/collection/diagnostics", "collection diagnostics"},
        {"/matches", "matches list"},
        {"/cards", "cards"},
        {"/decks", "decks list (default filter)"},
        {"/decks?filter=played", "decks list filter=played"},
        {"/decks?filter=all", "decks list filter=all"},
        {"/drafts", "drafts list"},
        {"/settings", "settings"},
        {"/operations", "operations"},
        {"/operations/mtga-memory", "operations mtga memory"},
        {"/console", "console"}
      ] do
    test "#{label} (#{path}) renders without crashing", %{conn: conn} do
      assert {:ok, _view, html} = live_within!(conn, unquote(path))
      assert is_binary(html)
    end
  end

  describe "/setup" do
    setup do
      # ConnCase marks setup completed by default. The setup tour route
      # only renders meaningfully when setup is *not* complete, so reset
      # the flag for this test and restore it on exit.
      :ok = SetupFlow.reset!()
      on_exit(fn -> SetupFlow.mark_completed!() end)
      :ok
    end

    test "renders without crashing", %{conn: conn} do
      assert {:ok, _view, html} = live_within!(conn, "/setup")
      assert is_binary(html)
    end
  end

  describe "/matches/:id" do
    setup do
      %{player: seed_active_player()}
    end

    test "renders match detail", %{conn: conn, player: player} do
      match = TestFactory.create_match(%{player_id: player.id})
      assert {:ok, _view, html} = live_within!(conn, "/matches/#{match.id}")
      assert is_binary(html)
    end
  end

  describe "/decks/:deck_id" do
    setup do
      %{deck: TestFactory.create_deck()}
    end

    for tab <- [nil, "overview", "analysis", "matches", "changes"] do
      tab_label = tab || "default"
      query = if tab, do: "?tab=#{tab}", else: ""

      test "renders deck detail tab=#{tab_label}", %{conn: conn, deck: deck} do
        path = "/decks/#{deck.mtga_deck_id}#{unquote(query)}"
        assert {:ok, _view, html} = live_within!(conn, path)
        assert is_binary(html)
      end
    end

    # Synthetic deck IDs use the form "<match_id>:seat<n>" when the player is
    # on a Momir-style deck whose identity can't be resolved (see
    # `Scry2.Events.IngestionState`). The colon must survive routing — Plug.Static
    # rejects path segments with colons when `raise_on_missing_only` is true,
    # so this guards against re-introducing that endpoint flag.
    test "renders deck detail when mtga_deck_id contains a colon", %{conn: conn} do
      synthetic_id = "match-#{System.unique_integer([:positive])}:seat1"
      deck = TestFactory.create_deck(%{mtga_deck_id: synthetic_id})
      assert {:ok, _view, html} = live_within!(conn, "/decks/#{deck.mtga_deck_id}")
      assert is_binary(html)
    end
  end

  describe "/drafts/:id" do
    setup do
      player = seed_active_player()
      draft = TestFactory.create_draft(%{player_id: player.id})
      _pick = TestFactory.create_pick(%{draft: draft})
      %{draft: draft}
    end

    for tab <- [nil, "picks", "deck", "matches"] do
      tab_label = tab || "default"
      query = if tab, do: "?tab=#{tab}", else: ""

      test "renders draft detail tab=#{tab_label}", %{conn: conn, draft: draft} do
        path = "/drafts/#{draft.id}#{unquote(query)}"
        assert {:ok, _view, html} = live_within!(conn, path)
        assert is_binary(html)
      end
    end
  end

  defp live_within!(conn, path) do
    budget = render_budget_ms()
    {micros, result} = :timer.tc(fn -> live(conn, path) end)
    ms = div(micros, 1000)

    if ms > budget do
      flunk(
        "Page #{path} mount took #{ms}ms, exceeds #{budget}ms budget (#{env_label()}). " <>
          "This is a local app — mounts should be near-instant."
      )
    end

    result
  end

  defp render_budget_ms do
    if System.get_env("CI") == "true",
      do: @render_budget_ci_ms,
      else: @render_budget_local_ms
  end

  defp env_label do
    if System.get_env("CI") == "true", do: "CI", else: "local"
  end

  defp warmup_once(conn) do
    if :persistent_term.get(@warmup_flag, false) do
      :ok
    else
      _ = live(conn, "/")
      :persistent_term.put(@warmup_flag, true)
      :ok
    end
  end
end
