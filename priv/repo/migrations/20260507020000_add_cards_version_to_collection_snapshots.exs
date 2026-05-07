defmodule Scry2.Repo.Migrations.AddCardsVersionToCollectionSnapshots do
  use Ecto.Migration

  def change do
    alter table(:collection_snapshots) do
      # MTGA's `_playerCardsVersion` (i32 monotonic counter on
      # InventoryManager). Bumps every time the player's card collection
      # changes — pack open, draft pick, vault open, anything that adds
      # or removes a card. Stamping it on each snapshot lets the reader
      # short-circuit the full cards-dictionary walk on subsequent polls
      # when the value hasn't moved (steady-state polling = the common
      # case).
      add :mtga_player_cards_version, :integer
    end
  end
end
