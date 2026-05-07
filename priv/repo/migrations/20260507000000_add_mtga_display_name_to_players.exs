defmodule Scry2.Repo.Migrations.AddMtgaDisplayNameToPlayers do
  use Ecto.Migration

  def change do
    alter table(:players) do
      # MTGA's screen-name-with-discriminator (e.g. "Shawn McCool#91813").
      # Read from MTGA memory via Scry2.Collection's account walker; the
      # log-derived `screen_name` carries only the bare name without
      # `#NNNNN`. Nullable — the value populates lazily once the
      # collection refresh job runs after MTGA login.
      add :mtga_display_name, :string
    end
  end
end
