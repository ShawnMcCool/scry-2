defmodule Scry2.Repo.Migrations.RestoreDraftsPicksOnDeleteCascade do
  use Ecto.Migration

  # The prior migration (20260414155631) recreated drafts_picks but omitted
  # ON DELETE CASCADE on the draft_id FK. Without it, deleting a draft row
  # raises a FOREIGN KEY constraint error. This migration restores the cascade.
  def up do
    execute("""
    CREATE TABLE drafts_picks_new (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      draft_id INTEGER NOT NULL REFERENCES drafts_drafts(id) ON DELETE CASCADE,
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
    execute("CREATE INDEX drafts_picks_picked_arena_id_index ON drafts_picks (picked_arena_id)")
  end

  def down do
    execute("""
    CREATE TABLE drafts_picks_old (
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
    INSERT INTO drafts_picks_old
      SELECT id, draft_id, pack_number, pick_number, picked_arena_id,
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
    execute("CREATE INDEX drafts_picks_picked_arena_id_index ON drafts_picks (picked_arena_id)")
  end
end
