defmodule Scry2.Repo.Migrations.NetdeckingCompositionKey do
  use Ecto.Migration

  @moduledoc """
  Replaces `netdecking_decks.composition_hash` (27-bit `phash2` over the
  resolved maindeck only) with `composition_key` — the SHA-256 content
  identity from `Scry2.NetDecking.CompositionKey`, covering the resolved
  maindeck plus normalized unresolved references.

  The old hash allowed duplicates two ways: `ReingestUnresolved` corrects
  rows in place by id, so two rows could converge on one composition without
  ever merging; and nothing at the database level enforced uniqueness. This
  migration backfills the new key from each row's stored card lists, deletes
  the later row of any group that already shares a key (same content by
  construction — the key is a cryptographic digest of the full known list),
  and adds a unique index on `(composition_key, format)`.
  """

  import Ecto.Query

  alias Scry2.NetDecking.CompositionKey

  def up do
    alter table(:netdecking_decks) do
      add :composition_key, :string
    end

    flush()

    backfill_composition_keys()
    delete_converged_duplicates()

    drop index(:netdecking_decks, [:composition_hash, :format])

    alter table(:netdecking_decks) do
      remove :composition_hash
    end

    create unique_index(:netdecking_decks, [:composition_key, :format])
  end

  def down do
    drop index(:netdecking_decks, [:composition_key, :format])

    alter table(:netdecking_decks) do
      add :composition_hash, :integer
    end

    flush()

    backfill_legacy_hashes()

    alter table(:netdecking_decks) do
      remove :composition_key
    end

    create index(:netdecking_decks, [:composition_hash, :format])
  end

  defp backfill_composition_keys do
    for row <- all_rows() do
      key = CompositionKey.compute(cards(row.main_deck), cards(row.unresolved_cards))

      repo().update_all(
        from(deck in "netdecking_decks", where: deck.id == ^row.id),
        set: [composition_key: key]
      )
    end
  end

  # Rows sharing a (composition_key, format) pair hold the same known card
  # list — the key is a digest of the full composition, so no further
  # content comparison is needed. Keep the earliest row of each group.
  defp delete_converged_duplicates do
    duplicate_ids =
      repo().all(
        from(deck in "netdecking_decks",
          where: not is_nil(deck.composition_key),
          select: {deck.id, deck.composition_key, deck.format}
        )
      )
      |> Enum.group_by(fn {_id, key, format} -> {key, format} end)
      |> Enum.flat_map(fn {_group, rows} ->
        rows
        |> Enum.map(fn {id, _key, _format} -> id end)
        |> Enum.sort()
        |> tl()
      end)

    if duplicate_ids != [] do
      repo().delete_all(from(deck in "netdecking_decks", where: deck.id in ^duplicate_ids))
    end
  end

  # Best-effort reversal: the legacy hash covered the resolved maindeck only;
  # its all-unresolved fallback hashed raw parser refs, which are not stored,
  # so those rows revert to a nil hash.
  defp backfill_legacy_hashes do
    for row <- all_rows() do
      hash = Scry2.Decks.composition_hash(cards(row.main_deck))

      repo().update_all(
        from(deck in "netdecking_decks", where: deck.id == ^row.id),
        set: [composition_hash: hash]
      )
    end
  end

  defp all_rows do
    repo().all(
      from(deck in "netdecking_decks",
        select: %{id: deck.id, main_deck: deck.main_deck, unresolved_cards: deck.unresolved_cards}
      )
    )
  end

  defp cards(nil), do: []

  defp cards(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"cards" => cards}} when is_list(cards) -> cards
      _decoded -> []
    end
  end
end
