defmodule Scry2.NetDecking.IngestDecklist do
  @moduledoc """
  The single ingestion funnel for the NetDecking corpus. Every source —
  manual paste today, automated adapters later — flows through these stages:

      Parse    (MtgaClipboardParser: text → refs)
      Resolve  (Cards.resolve_references: refs → {resolved, unresolved})
      Dedup    (Decks.composition_hash: idempotent key over maindeck)
      Persist  (upsert netdecking_decks by composition_hash)

  Buildability is NOT computed here — ingestion produces only
  collection-independent facts.
  """
  import Ecto.Query

  alias Scry2.Cards
  alias Scry2.Decks
  alias Scry2.Decks.MtgaClipboardParser
  alias Scry2.NetDecking.Deck
  alias Scry2.Repo

  @type attrs :: %{
          required(:name) => String.t(),
          required(:source_name) => String.t(),
          required(:decklist_text) => String.t(),
          optional(:archetype) => String.t(),
          optional(:format) => String.t(),
          optional(:source_url) => String.t(),
          optional(:pilot) => String.t(),
          optional(:event_name) => String.t(),
          optional(:event_date) => Date.t(),
          optional(:placement) => pos_integer(),
          optional(:swiss_rank) => pos_integer(),
          optional(:field_size) => pos_integer(),
          optional(:wins) => non_neg_integer(),
          optional(:losses) => non_neg_integer()
        }

  @spec run(attrs()) :: {:ok, Deck.t()} | {:error, Ecto.Changeset.t()}
  def run(%{decklist_text: text} = attrs) do
    %{main: main_refs, sideboard: side_refs} = MtgaClipboardParser.parse(text)

    main = Cards.resolve_references(main_refs)
    side = Cards.resolve_references(side_refs)

    main_cards = to_card_maps(main.resolved)
    side_cards = to_card_maps(side.resolved)

    composition_hash =
      Decks.composition_hash(main_cards) || :erlang.phash2({main_refs, side_refs})

    unresolved = normalize_unresolved(main.unresolved ++ side.unresolved)

    persist(attrs, main_cards, side_cards, unresolved, composition_hash)
  end

  defp to_card_maps(resolved) do
    Enum.map(resolved, fn %{arena_id: arena_id, count: count} ->
      %{"arena_id" => arena_id, "count" => count}
    end)
  end

  defp normalize_unresolved(refs) do
    Enum.map(refs, fn ref ->
      %{
        "name" => ref.name,
        "set_code" => ref.set_code,
        "collector_number" => ref.collector_number,
        "count" => ref.count
      }
    end)
  end

  defp persist(attrs, main_cards, side_cards, unresolved, composition_hash) do
    row = existing(composition_hash)

    changeset =
      Deck.changeset(row || %Deck{}, %{
        name: attrs.name,
        archetype: attrs[:archetype],
        format: attrs[:format] || "Standard",
        main_deck: %{"cards" => main_cards},
        sideboard: %{"cards" => side_cards},
        composition_hash: composition_hash,
        source_name: attrs.source_name,
        source_url: attrs[:source_url],
        fetched_at: DateTime.utc_now(),
        unresolved_cards: %{"cards" => unresolved},
        pilot: attrs[:pilot],
        event_name: attrs[:event_name],
        event_date: attrs[:event_date],
        placement: attrs[:placement],
        swiss_rank: attrs[:swiss_rank],
        field_size: attrs[:field_size],
        wins: attrs[:wins],
        losses: attrs[:losses]
      })

    Repo.insert_or_update(changeset)
  end

  defp existing(nil), do: nil

  defp existing(composition_hash) do
    Deck
    |> where([d], d.composition_hash == ^composition_hash)
    |> limit(1)
    |> Repo.one()
  end
end
