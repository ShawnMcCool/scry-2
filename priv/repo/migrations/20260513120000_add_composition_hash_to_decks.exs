defmodule Scry2.Repo.Migrations.AddCompositionHashToDecks do
  use Ecto.Migration

  # Adds `composition_hash` to `decks_decks` so the DeckSubmitted projector
  # can identify a constructed deck by composition with one indexed lookup
  # instead of scanning every row and Elixir-side comparing card lists.
  #
  # The hash is `:erlang.phash2/1` of `Enum.sort([{arena_id, count}, ...])`
  # over the main deck. Sideboards change between BO3 games so they are not
  # part of the hash, matching the matching rule in the projector.

  def up do
    alter table(:decks_decks) do
      add :composition_hash, :integer
    end

    flush()

    backfill_composition_hash()

    create index(:decks_decks, [:composition_hash])
  end

  def down do
    drop_if_exists index(:decks_decks, [:composition_hash])

    alter table(:decks_decks) do
      remove :composition_hash
    end
  end

  defp backfill_composition_hash do
    {:ok, %{rows: rows}} =
      repo().query(
        "SELECT id, current_main_deck FROM decks_decks WHERE current_main_deck IS NOT NULL"
      )

    Enum.each(rows, fn [id, current_main_deck] ->
      case decode(current_main_deck) do
        %{"cards" => cards} when is_list(cards) and cards != [] ->
          hash =
            cards
            |> Enum.map(&card_pair/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.sort()
            |> :erlang.phash2()

          repo().query!("UPDATE decks_decks SET composition_hash = ? WHERE id = ?", [hash, id])

        _ ->
          :ok
      end
    end)
  end

  defp decode(nil), do: nil
  defp decode(map) when is_map(map), do: map

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp card_pair(card) when is_map(card) do
    arena_id = card["arena_id"] || card[:arena_id]
    count = card["count"] || card[:count]
    if arena_id && count, do: {arena_id, count}, else: nil
  end

  defp card_pair(_), do: nil
end
