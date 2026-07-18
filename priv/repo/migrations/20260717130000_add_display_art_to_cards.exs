defmodule Scry2.Repo.Migrations.AddDisplayArtToCards do
  @moduledoc """
  Canonical display art stamped at synthesis time: every `cards_cards`
  row carries the image URLs of the most basic printing sharing the
  card's name (`Scry2.Cards.BasicPrinting`). Read paths become a column
  read. Nullable — unstamped rows fall back to ImageCache's live-API
  path until the next synthesis run stamps them.
  """
  use Ecto.Migration

  def change do
    alter table(:cards_cards) do
      add :image_url, :string
      add :art_crop_url, :string
    end
  end
end
