defmodule Scry2.Repo.Migrations.DenormalizeBoosterAndSetCodeOnScryfallCards do
  use Ecto.Migration

  def up do
    alter table(:cards_scryfall_cards) do
      add :booster, :boolean
    end

    # Normalize set_code to uppercase so joins to cards_mtga_cards.expansion_code
    # (which is uppercase from the MTGA client) can use the (set_code, collector_number)
    # composite index without upper() function wrapping.
    # Also populate booster from the raw JSON — avoids json_extract on the full raw blob
    # in deduplicate_by_name queries.
    execute """
    UPDATE cards_scryfall_cards
    SET set_code = upper(set_code),
        booster = (json_extract(raw, '$.booster') = 1)
    """
  end

  def down do
    execute "UPDATE cards_scryfall_cards SET set_code = lower(set_code)"

    alter table(:cards_scryfall_cards) do
      remove :booster
    end
  end
end
