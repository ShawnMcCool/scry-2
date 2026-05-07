defmodule Scry2.Repo.Migrations.AddEnvironmentToCollectionSnapshots do
  use Ecto.Migration

  def change do
    alter table(:collection_snapshots) do
      # Server-environment record (spike 23). Memory-read from
      # PAPA._instance.<FdConnectionManager>k__BackingField →
      # FrontDoorConnectionManager._currentEnvironment →
      # EnvironmentDescription. Stamped on every snapshot so historical
      # snapshots stay self-describing across MTGA self-updates that
      # change the front-door host.
      #
      # Public, non-secret fields only — see walker/environment.rs for
      # the security boundary.
      add :mtga_environment_name, :string
      add :mtga_fd_host, :string
      add :mtga_fd_port, :integer
      add :mtga_host_platform, :integer
    end
  end
end
