defmodule Scry2.Repo.Migrations.AddCosmeticsToCollectionSnapshots do
  use Ecto.Migration

  def change do
    alter table(:collection_snapshots) do
      # Memory-read cosmetics summary, JSON blob shaped as
      # %{"available" => %{"art_styles" => N, "avatars" => N, ...},
      #   "owned" => %{...},
      #   "equipped" => %{"avatar" => "...", "card_back" => "...", ...}}.
      #
      # Stored as one column rather than 12 ints + 4 strings because
      # cosmetics aren't queried — they're read back as a single
      # struct and rendered. Keeps the schema flat.
      add :cosmetics_json, :string
    end
  end
end
