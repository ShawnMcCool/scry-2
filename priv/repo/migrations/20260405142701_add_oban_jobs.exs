defmodule Scry2.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 12, engine: Oban.Engines.Lite)
  end

  def down do
    Oban.Migration.down(version: 1, engine: Oban.Engines.Lite)
  end
end
