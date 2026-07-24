defmodule Scry2.NetDecking.ReingestUnresolved do
  @moduledoc """
  Re-runs the ingestion funnel for corpus decks that still carry unresolved
  card references, so references the card data now covers stop being dropped.

  A deck is ingested once, at fetch time. If the local MTGA card data lacked a
  card then, that reference was stored under `unresolved_cards` and the deck
  reads as `:incomplete`. When the card data later improves — e.g. a Universes
  Beyond set's alternate names get bridged in `Cards.resolve_references/1` —
  those rows stay stale, because nothing re-resolves an already-stored deck.

  This walks the stale rows, re-fetches each deck's source event, and re-runs
  it through the funnel **in place** (`IngestDecklist.reingest/2`), preserving
  the deck id. Re-resolving changes the composition (and its hash) whenever a
  maindeck reference newly resolves, so a plain hash-keyed re-ingest would
  spawn a duplicate instead of correcting the row.

  Only `mtgo`-sourced decks with a `source_url` are re-fetchable today. The
  event fetch is injectable (`:fetch_event`) so the walk is testable without
  the network.

  Options:
    * `:apply` — `false` (default) reports the plan without writing; `true`
      performs the in-place re-ingest.
    * `:only` — list of deck ids to restrict the walk to (defaults to all
      candidates).
    * `:fetch_event` — 1-arity fun `url -> {:ok, [raw_deck]} | {:error, term}`
      (defaults to `Sources.MtgoSource.fetch_event/1`).
  """
  import Ecto.Query

  alias Scry2.NetDecking.{Deck, IngestDecklist}
  alias Scry2.NetDecking.Sources.MtgoSource
  alias Scry2.Repo

  require Scry2.Log, as: Log

  @type report :: %{
          candidates: non_neg_integer(),
          events: non_neg_integer(),
          would_reingest: non_neg_integer(),
          reingested: non_neg_integer(),
          unmatched: non_neg_integer(),
          failed_events: non_neg_integer()
        }

  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)
    only = Keyword.get(opts, :only)
    fetch_event = Keyword.get(opts, :fetch_event, &MtgoSource.fetch_event/1)

    candidates = candidate_decks(only)
    by_event = Enum.group_by(candidates, & &1.source_url)

    initial = %{
      candidates: length(candidates),
      events: map_size(by_event),
      would_reingest: 0,
      reingested: 0,
      unmatched: 0,
      failed_events: 0
    }

    Enum.reduce(by_event, initial, fn {url, decks}, acc ->
      case fetch_event.(url) do
        {:ok, raw_decks} ->
          reingest_event(decks, raw_decks, apply?, acc)

        {:error, reason} ->
          Log.warning(:importer, "reingest: event #{url} fetch failed: #{inspect(reason)}")
          %{acc | failed_events: acc.failed_events + 1}
      end
    end)
  end

  # Stale = still-unresolved, and from a source we can re-fetch (mtgo + a url).
  defp candidate_decks(only) do
    Deck
    |> where([d], d.source_name == "mtgo" and not is_nil(d.source_url))
    |> where(
      [d],
      fragment("json_array_length(json_extract(?, ?)) > 0", d.unresolved_cards, "$.cards")
    )
    |> maybe_only(only)
    |> Repo.all()
  end

  defp maybe_only(query, nil), do: query
  defp maybe_only(query, ids), do: where(query, [d], d.id in ^ids)

  defp reingest_event(decks, raw_decks, apply?, acc) do
    by_pilot = Map.new(raw_decks, fn raw -> {normalize_pilot(raw[:pilot]), raw} end)
    by_name = Map.new(raw_decks, fn raw -> {raw[:name], raw} end)

    Enum.reduce(decks, acc, fn deck, acc ->
      case match_raw(deck, by_pilot, by_name) do
        nil ->
          Log.warning(
            :importer,
            "reingest: no source deck for #{deck.id} (pilot #{inspect(deck.pilot)})"
          )

          %{acc | unmatched: acc.unmatched + 1}

        raw ->
          apply_one(deck, raw, apply?, acc)
      end
    end)
  end

  # Pilot is the primary key (unique per MTGO event). Older ingests stored the
  # pilot only in the deck name, so fall back to an exact name match when the
  # pilot field is absent.
  defp match_raw(deck, by_pilot, by_name) do
    pilot_match = deck.pilot && Map.get(by_pilot, normalize_pilot(deck.pilot))
    pilot_match || Map.get(by_name, deck.name)
  end

  defp apply_one(_deck, _raw, false, acc), do: %{acc | would_reingest: acc.would_reingest + 1}

  defp apply_one(deck, raw, true, acc) do
    attrs = Map.put(raw, :source_name, deck.source_name)

    case IngestDecklist.reingest(deck, attrs) do
      {:ok, _deck} ->
        %{acc | reingested: acc.reingested + 1}

      {:error, reason} ->
        Log.warning(:importer, "reingest: deck #{deck.id} failed: #{inspect(reason)}")
        acc
    end
  end

  defp normalize_pilot(nil), do: nil
  defp normalize_pilot(pilot), do: pilot |> String.downcase() |> String.trim()
end
