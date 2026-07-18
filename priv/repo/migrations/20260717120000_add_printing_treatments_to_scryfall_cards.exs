defmodule Scry2.Repo.Migrations.AddPrintingTreatmentsToScryfallCards do
  @moduledoc """
  Printing-treatment metadata from Scryfall bulk data, used to rank a
  card name's printings by basicness (`Scry2.Cards.BasicPrinting`) so
  every card image in the app is the most basic printing's art.
  Populated on the next Scryfall import; additive only.
  """
  use Ecto.Migration

  def change do
    alter table(:cards_scryfall_cards) do
      add :promo, :boolean, null: false, default: false
      add :full_art, :boolean, null: false, default: false
      add :variation, :boolean, null: false, default: false
      add :frame_effects, :string, null: false, default: ""
      add :border_color, :string
    end
  end
end
