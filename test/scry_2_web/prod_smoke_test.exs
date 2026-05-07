defmodule Scry2Web.ProdSmokeTest do
  @moduledoc """
  Mounts every page+tab against a snapshot of the user's production
  database. Catches the class of bug where a render branch only fires
  on real-shaped data — the kind that synthetic factories miss.

  The synthetic `page_smoke_test.exs` only exercises empty-state render
  branches. Real prod data flows through different branches: populated
  card pools, real `%Cards.Card{}` structs (with `:types`, not
  `:type_line`), submitted decks, etc. The v0.32.0 prod crash on
  /drafts/:id?tab=deck is the canonical example.

  ## Running

      mix test --only prod_smoke

  Or via the alias:

      mix test.prod_smoke

  Skipped automatically when no prod DB exists (CI / fresh checkouts).
  Tagged `:prod_smoke` so it does not run during default `mix test` or
  `mix precommit`.

  ## Mechanics

  The user's prod DB lives at `~/.local/share/scry_2/scry_2.db` and is
  written to by the running prod app — touching it directly is unsafe.
  Instead, `setup_all` snapshots it to `_build/test/prod_smoke.db`,
  swaps `Scry2.Repo` to point at the snapshot, restarts the Repo, and
  restores everything on teardown. Tests query the prod-shaped data via
  the standard schemas and mount every URL via `live/2`.
  """

  use Scry2Web.ConnCase, async: false

  @moduletag :prod_smoke

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Scry2.Decks.Deck
  alias Scry2.Drafts.Draft
  alias Scry2.Matches.Match
  alias Scry2.Repo

  @prod_db_path Path.expand("~/.local/share/scry_2/scry_2.db")
  @snapshot_path Path.expand("../../_build/test/prod_smoke.db", __DIR__)

  setup_all do
    cond do
      System.get_env("CI") == "true" ->
        {:ok, prod_smoke_skipped: "CI environment"}

      not File.exists?(@prod_db_path) ->
        {:ok, prod_smoke_skipped: "no prod DB at #{@prod_db_path}"}

      true ->
        snapshot_prod_db!()
        :ok
    end
  end

  describe "every URL against prod-shaped data" do
    test "static index pages all return 200", %{conn: conn} do
      paths = [
        "/",
        "/player",
        "/ranks",
        "/economy",
        "/match-economy",
        "/collection",
        "/collection/diagnostics",
        "/matches",
        "/cards",
        "/decks",
        "/decks?filter=played",
        "/decks?filter=all",
        "/drafts",
        "/settings",
        "/operations",
        "/operations/mtga-memory",
        "/console"
      ]

      assert_all_mount(conn, paths)
    end

    test "every draft mounts every tab", %{conn: conn} do
      ids = Repo.all(from d in Draft, select: d.id, order_by: d.id)

      paths =
        for id <- ids,
            tab <- [nil, "picks", "deck", "matches"] do
          if tab, do: "/drafts/#{id}?tab=#{tab}", else: "/drafts/#{id}"
        end

      assert_all_mount(conn, paths)
    end

    test "every match detail mounts", %{conn: conn} do
      ids = Repo.all(from m in Match, select: m.id, order_by: m.id)
      paths = Enum.map(ids, &"/matches/#{&1}")
      assert_all_mount(conn, paths)
    end

    test "every deck mounts every tab", %{conn: conn} do
      mtga_ids = Repo.all(from d in Deck, select: d.mtga_deck_id, order_by: d.id)

      paths =
        for id <- mtga_ids,
            tab <- [nil, "overview", "analysis", "matches", "changes"] do
          if tab, do: "/decks/#{id}?tab=#{tab}", else: "/decks/#{id}"
        end

      assert_all_mount(conn, paths)
    end
  end

  defp assert_all_mount(conn, paths) do
    failures =
      paths
      |> Enum.flat_map(fn path ->
        try do
          case live(conn, path) do
            {:ok, _view, _html} -> []
            {:error, reason} -> [{path, inspect(reason)}]
          end
        rescue
          error -> [{path, Exception.message(error)}]
        end
      end)

    if failures != [] do
      detail = Enum.map_join(failures, "\n", fn {path, why} -> "  #{path}\n    #{why}" end)
      flunk("#{length(failures)} of #{length(paths)} pages crashed:\n#{detail}")
    end
  end

  defp snapshot_prod_db! do
    original_config = Application.get_env(:scry_2, Repo)
    File.mkdir_p!(Path.dirname(@snapshot_path))
    File.cp!(@prod_db_path, @snapshot_path)

    # Apply any pending dev-side migrations to the snapshot **before**
    # swapping `Scry2.Repo` over to it. We open a one-off Exqlite
    # connection on the snapshot file, walk every migration's
    # `change/0` body, and emit equivalent DDL via raw SQL — avoiding
    # the Ecto.Migrator + sandbox interaction that breaks in a
    # ConnCase setup_all.
    apply_pending_alters_to_snapshot!(@snapshot_path)

    swap_repo!(original_config, Keyword.put(original_config, :database, @snapshot_path))

    on_exit(fn ->
      swap_repo!(Application.get_env(:scry_2, Repo), original_config)
      File.rm(@snapshot_path)
    end)
  end

  # Hand-maintained list of column additions that must reach the prod
  # snapshot before the dev branch's render code touches it. Add a
  # row here in the same PR as any new `add :column, …` in a
  # migration. Each row is `{table, column, sql_type}`. Idempotent —
  # checks the existing schema first, no-ops if the column is
  # already present (so older prod DBs that already have the column
  # don't trip "duplicate column" errors).
  @prod_smoke_additive_columns [
    {"players", "mtga_display_name", "TEXT"},
    {"collection_snapshots", "cosmetics_json", "TEXT"}
  ]

  defp apply_pending_alters_to_snapshot!(path) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    try do
      Enum.each(@prod_smoke_additive_columns, fn {table, column, type} ->
        if not column_exists?(conn, table, column) do
          :ok =
            Exqlite.Sqlite3.execute(
              conn,
              "ALTER TABLE #{table} ADD COLUMN #{column} #{type}"
            )
        end
      end)
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp column_exists?(conn, table, column) do
    {:ok, statement} =
      Exqlite.Sqlite3.prepare(conn, "PRAGMA table_info(#{table})")

    rows = drain_pragma(conn, statement, [])
    :ok = Exqlite.Sqlite3.release(conn, statement)
    Enum.any?(rows, fn [_cid, name | _] -> name == column end)
  end

  defp drain_pragma(conn, statement, acc) do
    case Exqlite.Sqlite3.step(conn, statement) do
      :done -> Enum.reverse(acc)
      {:row, row} -> drain_pragma(conn, statement, [row | acc])
    end
  end

  defp swap_repo!(_current, target_config) do
    :ok = Supervisor.terminate_child(Scry2.Supervisor, Repo)
    Application.put_env(:scry_2, Repo, target_config)
    {:ok, _pid} = Supervisor.restart_child(Scry2.Supervisor, Repo)
    :ok
  end
end
