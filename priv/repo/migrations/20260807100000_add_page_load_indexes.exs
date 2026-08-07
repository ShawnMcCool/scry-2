defmodule Scry2.Repo.Migrations.AddPageLoadIndexes do
  use Ecto.Migration

  # Indexes for two full-table scans found in the page-load performance audit.
  # Both are pure read-path additions — no column or row is touched.

  def change do
    # `MtgaLogIngestion.count_errors/0` and `list_errors/1` filter on
    # `processing_error IS NOT NULL AND dismissed_at IS NULL`. Neither column
    # was indexed, so both scanned all of `mtga_logs_events` — 952k rows /
    # 824 MB, measured at ~240 ms per call. `/operations` calls it on both the
    # dead render and the connected mount.
    #
    # A partial index over exactly that predicate holds only the errored,
    # non-dismissed rows (normally near zero), so the count reads a handful of
    # index pages instead of the whole table.
    #
    # SQLite decides a partial index applies by *syntactic* implication, so
    # this `where:` must match what the query renders, verbatim. Every caller
    # goes through `MtgaLogIngestion.unresolved_errors_query/0`, which uses a
    # `fragment("? IS NOT NULL", …)` for precisely this reason — Ecto's
    # `not is_nil(x)` renders as `NOT (x IS NULL)`, which SQLite does not match
    # against `x IS NOT NULL`. `mtga_log_ingestion_test.exs` asserts the plan.
    create_if_not_exists index(:mtga_logs_events, [:id],
                           where: "processing_error IS NOT NULL AND dismissed_at IS NULL",
                           name: :mtga_logs_events_unresolved_errors_index
                         )

    # `Cards.printings_by_name/1` and `representative_arena_ids/1` filter and
    # group on `lower(name)`. The existing `cards_cards_name_index` is on the
    # raw column, which SQLite cannot use for an expression, so both scanned
    # all 26k rows (~16-26 ms per call, several calls per deck/match page).
    #
    # An expression index on `lower(name)` matches those queries as written.
    # `printings_by_name/1` also selects `lower(name)` alongside `arena_id`,
    # so including `arena_id` lets it serve the query from the index alone.
    create_if_not_exists index(:cards_cards, ["lower(name)", :arena_id],
                           name: :cards_cards_lower_name_arena_id_index
                         )
  end
end
