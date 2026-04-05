defmodule Scry2.MtgaLogs.Cursor do
  @moduledoc """
  Ecto schema for the tail offset cursor (table `mtga_logs_cursor`).

  One row per watched file, keyed by absolute `file_path`. Updated after
  every successful batch so the watcher can resume exactly where it left
  off after a restart (see ADR-012 — durable process design).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "mtga_logs_cursor" do
    field :file_path, :string
    field :byte_offset, :integer, default: 0
    field :inode, :integer
    field :last_read_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [:file_path, :byte_offset, :inode, :last_read_at])
    |> validate_required([:file_path, :byte_offset])
    |> unique_constraint(:file_path)
  end
end
