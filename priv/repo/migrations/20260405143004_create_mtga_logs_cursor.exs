defmodule Scry2.Repo.Migrations.CreateMtgaLogsCursor do
  use Ecto.Migration

  def change do
    create table(:mtga_logs_cursor) do
      add :file_path, :string, null: false
      add :byte_offset, :integer, default: 0, null: false
      add :inode, :integer
      add :last_read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:mtga_logs_cursor, [:file_path])
  end
end
