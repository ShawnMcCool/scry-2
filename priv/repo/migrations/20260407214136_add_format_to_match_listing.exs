defmodule Scry2.Repo.Migrations.AddFormatToMatchListing do
  use Ecto.Migration

  def change do
    alter table(:matches_match_listing) do
      add :format, :string
      add :format_type, :string
    end
  end
end
