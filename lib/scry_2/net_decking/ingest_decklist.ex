defmodule Scry2.NetDecking.IngestDecklist do
  @moduledoc """
  The single ingestion funnel for the NetDecking corpus. Every source —
  manual paste today, automated adapters later — flows through these stages:

      Parse    (MtgaClipboardParser: text → refs)
      Resolve  (Cards.resolve_references: refs → {resolved, unresolved})
      Dedup    (Decks.composition_hash: idempotent key over maindeck)
      Classify (Metagame.classification_attrs: card lists → archetype columns)
      Persist  (upsert netdecking_decks by composition_hash)

  Buildability is NOT computed here — ingestion produces only
  collection-independent facts.

  A source can list the same card on two separate decklist lines (MTGO
  splits some cards across set/printing groupings within one player's
  list). `Cards.resolve_references/1` resolves each line independently by
  design ("never drops a ref"), so duplicate `arena_id`s reach this module
  as separate entries — merged into one summed entry per `arena_id` before
  persisting, so every downstream reader of `main_deck`/`sideboard` (score,
  buildability cost, archetype-core deltas) sees one true count per card.
  """
  import Ecto.Query

  alias Scry2.Cards
  alias Scry2.Decks
  alias Scry2.Decks.MtgaClipboardParser
  alias Scry2.Metagame
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
  def run(%{decklist_text: _} = attrs) do
    computed = compute(attrs)
    format = attrs[:format] || "Standard"
    row = existing(computed.composition_hash, format)
    persist(row || %Deck{}, attrs, computed)
  end

  @doc """
  Re-runs the funnel for a deck that is already in the corpus, updating that
  exact row in place (by id) rather than deduping by `composition_hash`. Used
  when the card data has improved and previously-unresolved references now
  resolve: the composition — and therefore the hash — changes, so the normal
  hash-keyed upsert would spawn a fresh row and orphan the stale one. Keeping
  the id preserves provenance clustering and any references to the deck.
  """
  @spec reingest(Deck.t(), attrs()) :: {:ok, Deck.t()} | {:error, Ecto.Changeset.t()}
  def reingest(%Deck{} = deck, %{decklist_text: _} = attrs) do
    persist(deck, attrs, compute(attrs))
  end

  # Collection-independent facts derived from the raw decklist text: resolved
  # main/sideboard card maps, the unresolved references, and the dedup hash.
  defp compute(%{decklist_text: text} = _attrs) do
    %{main: main_refs, sideboard: side_refs} = MtgaClipboardParser.parse(text)

    main = Cards.resolve_references(main_refs)
    side = Cards.resolve_references(side_refs)

    main_cards = to_card_maps(main.resolved)
    side_cards = to_card_maps(side.resolved)

    %{
      main_cards: main_cards,
      side_cards: side_cards,
      unresolved: normalize_unresolved(main.unresolved ++ side.unresolved),
      composition_hash:
        Decks.composition_hash(main_cards) || :erlang.phash2({main_refs, side_refs})
    }
  end

  defp to_card_maps(resolved) do
    resolved
    |> Enum.group_by(& &1.arena_id, & &1.count)
    |> Enum.map(fn {arena_id, counts} ->
      %{"arena_id" => arena_id, "count" => Enum.sum(counts)}
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

  defp persist(row, attrs, computed) do
    %{
      main_cards: main_cards,
      side_cards: side_cards,
      unresolved: unresolved,
      composition_hash: composition_hash
    } = computed

    format = attrs[:format] || "Standard"

    stamp =
      Metagame.classification_attrs(%{"cards" => main_cards}, %{"cards" => side_cards}, format)

    changeset =
      Deck.changeset(row, %{
        name: attrs.name,
        archetype: attrs[:archetype],
        archetype_name: stamp.archetype_name,
        archetype_variant: stamp.archetype_variant,
        archetype_fallback: stamp.archetype_fallback,
        format: format,
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

  defp existing(nil, _format), do: nil

  defp existing(composition_hash, format) do
    Deck
    |> where([d], d.composition_hash == ^composition_hash and d.format == ^format)
    |> limit(1)
    |> Repo.one()
  end
end
