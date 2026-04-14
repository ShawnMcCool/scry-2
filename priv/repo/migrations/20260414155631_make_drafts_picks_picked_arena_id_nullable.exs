defmodule Scry2.Repo.Migrations.MakeDraftsPicksPickedArenaIdNullable do
  use Ecto.Migration

  # SQLite does not support ALTER COLUMN, so we recreate the table with the
  # column made nullable. HumanDraftPackOffered creates pick rows before a
  # pick is confirmed, so picked_arena_id must allow NULL.
  def up do
    execute("""
    CREATE TABLE drafts_picks_new (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      draft_id INTEGER NOT NULL REFERENCES drafts_drafts(id),
      pack_number INTEGER NOT NULL,
      pick_number INTEGER NOT NULL,
      picked_arena_id INTEGER,
      pack_arena_ids TEXT,
      pool_arena_ids TEXT,
      picked_at TEXT,
      auto_pick INTEGER,
      time_remaining REAL,
      picked_arena_ids TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO drafts_picks_new
      SELECT id, draft_id, pack_number, pick_number, picked_arena_id,
             pack_arena_ids, pool_arena_ids, picked_at, auto_pick,
             time_remaining, picked_arena_ids, inserted_at, updated_at
      FROM drafts_picks
    """)

    execute("DROP TABLE drafts_picks")
    execute("ALTER TABLE drafts_picks_new RENAME TO drafts_picks")

    execute("""
    CREATE UNIQUE INDEX drafts_picks_draft_id_pack_number_pick_number_index
      ON drafts_picks (draft_id, pack_number, pick_number)
    """)

    execute("CREATE INDEX drafts_picks_draft_id_index ON drafts_picks (draft_id)")
  end

  def down do
    execute("""
    CREATE TABLE drafts_picks_old (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      draft_id INTEGER NOT NULL REFERENCES drafts_drafts(id),
      pack_number INTEGER NOT NULL,
      pick_number INTEGER NOT NULL,
      picked_arena_id INTEGER NOT NULL,
      pack_arena_ids TEXT,
      pool_arena_ids TEXT,
      picked_at TEXT,
      auto_pick INTEGER,
      time_remaining REAL,
      picked_arena_ids TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO drafts_picks_old
      SELECT id, draft_id, pack_number, pick_number,
             COALESCE(picked_arena_id, 0),
             pack_arena_ids, pool_arena_ids, picked_at, auto_pick,
             time_remaining, picked_arena_ids, inserted_at, updated_at
      FROM drafts_picks
    """)

    execute("DROP TABLE drafts_picks")
    execute("ALTER TABLE drafts_picks_old RENAME TO drafts_picks")

    execute("""
    CREATE UNIQUE INDEX drafts_picks_draft_id_pack_number_pick_number_index
      ON drafts_picks (draft_id, pack_number, pick_number)
    """)

    execute("CREATE INDEX drafts_picks_draft_id_index ON drafts_picks (draft_id)")
  end
end
