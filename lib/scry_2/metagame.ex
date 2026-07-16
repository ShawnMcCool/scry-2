defmodule Scry2.Metagame do
  @moduledoc """
  The Metagame bounded context: the format's competitive archetype
  vocabulary and deck classification against it.

  Definitions come from the community-maintained MTGOFormatData repo
  (culturally established archetype names and identifying rules). A
  vendored snapshot under `priv/metagame` seeds the tables on first
  read; `Scry2.Workers.PeriodicallyFetchArchetypeDefinitions` refreshes
  them daily.

  Pipeline: definition rows → `Definitions.build/3` → the pure
  `ClassifyDeck` engine. This facade resolves arena_id card lists to
  named entries via the Cards public API before classification.

  Consumers (NetDecking, Decks, Matches) call `classify/3` /
  `classify_observed/2` and stamp the result onto their own rows.
  """

  import Ecto.Query

  alias Scry2.Cards

  alias Scry2.Metagame.{
    ArchetypeDefinition,
    Classification,
    ClassifyDeck,
    ColorOverride,
    Definitions,
    ParseDefinitions
  }

  alias Scry2.Repo

  require Scry2.Log, as: Log

  @seed_dir Path.join(:code.priv_dir(:scry_2), "metagame/Formats")

  @doc """
  Classify a complete decklist given as `%{"cards" => [%{"arena_id",
  "count"}]}` card maps (the shape `decks_decks` and `netdecking_decks`
  store). Resolves cards via the Cards public API; unresolvable
  arena_ids are ignored.
  """
  @spec classify(map() | nil, map() | nil, String.t()) :: Classification.t() | :unknown
  def classify(main_deck, sideboard, format \\ "Standard") do
    main_refs = card_refs(main_deck)
    side_refs = card_refs(sideboard)

    case main_refs ++ side_refs do
      [] ->
        :unknown

      all_refs ->
        cards_by_arena_id = Cards.list_by_arena_ids(Enum.map(all_refs, & &1.arena_id))

        ClassifyDeck.run(
          entries(main_refs, cards_by_arena_id),
          entries(side_refs, cards_by_arena_id),
          definitions(format)
        )
    end
  end

  @doc """
  Classify from partial information — the opponent cards observed
  during a match, as `[%{arena_id, count}]`.
  """
  @spec classify_observed([%{arena_id: integer(), count: pos_integer()}], String.t()) ::
          Classification.t() | :unknown
  def classify_observed(observed, format \\ "Standard")

  def classify_observed([], _format), do: :unknown

  def classify_observed(observed, format) when is_list(observed) do
    refs = Enum.map(observed, &to_ref/1)
    cards_by_arena_id = Cards.list_by_arena_ids(Enum.map(refs, & &1.arena_id))
    ClassifyDeck.observed(entries(refs, cards_by_arena_id), definitions(format))
  end

  @doc """
  The loaded archetype vocabulary for `format`, lazily seeded from the
  vendored `priv/metagame` snapshot when the format has no rows yet.
  """
  @spec definitions(String.t()) :: Definitions.t()
  def definitions(format \\ "Standard") do
    case load(format) do
      %Definitions{archetypes: [], fallbacks: []} -> seed!(format)
      definitions -> definitions
    end
  end

  @doc """
  Replace the format's definition rows with freshly parsed content.

  Compares against the current rows first: returns `:unchanged` when the
  parsed content matches what is stored, `:updated` after a
  delete-and-insert in one transaction otherwise. An update broadcasts
  `{:definitions_updated, format}` on `metagame:updates`.
  """
  @spec replace_definitions!(String.t(), %{
          definitions: [ParseDefinitions.definition_attrs()],
          overrides: [ParseDefinitions.override_attrs()]
        }) :: :unchanged | :updated
  def replace_definitions!(format, %{definitions: definition_attrs, overrides: override_attrs}) do
    if comparable(load(format)) == comparable_attrs(format, definition_attrs, override_attrs) do
      :unchanged
    else
      {:ok, :updated} =
        Repo.transaction(fn ->
          Repo.delete_all(from d in ArchetypeDefinition, where: d.format == ^format)
          Repo.delete_all(from o in ColorOverride, where: o.format == ^format)
          insert_all!(format, definition_attrs, override_attrs)
          :updated
        end)

      Scry2.Topics.broadcast(Scry2.Topics.metagame_updates(), {:definitions_updated, format})
      :updated
    end
  end

  # ── Card resolution ─────────────────────────────────────────────────

  defp card_refs(%{"cards" => cards}) when is_list(cards), do: Enum.map(cards, &to_ref/1)
  defp card_refs(%{cards: cards}) when is_list(cards), do: Enum.map(cards, &to_ref/1)
  defp card_refs(_deck), do: []

  defp to_ref(%{"arena_id" => arena_id} = card),
    do: %{arena_id: arena_id, count: card["count"] || 1}

  defp to_ref(%{arena_id: arena_id} = card),
    do: %{arena_id: arena_id, count: Map.get(card, :count) || 1}

  defp entries(refs, cards_by_arena_id) do
    Enum.flat_map(refs, fn ref ->
      case Map.get(cards_by_arena_id, ref.arena_id) do
        nil ->
          []

        card ->
          [
            %{
              name: Map.get(card, :name) || "",
              count: ref.count,
              colors: Map.get(card, :color_identity) || "",
              land?: Map.get(card, :is_land) == true
            }
          ]
      end
    end)
    |> Enum.reject(&(&1.name == ""))
  end

  # ── Loading ─────────────────────────────────────────────────────────

  defp load(format) do
    definition_rows = Repo.all(from d in ArchetypeDefinition, where: d.format == ^format)
    override_rows = Repo.all(from o in ColorOverride, where: o.format == ^format)
    Definitions.build(format, definition_rows, override_rows)
  end

  defp seed!(format) do
    files = seed_files(format)

    if files == %{} do
      Log.warning(:importer, "metagame: no vendored definitions for format #{format}")
      Definitions.build(format, [], [])
    else
      %{definitions: definition_attrs, overrides: override_attrs, errors: errors} =
        ParseDefinitions.rows_from_files(files)

      Enum.each(errors, fn {path, reason} ->
        Log.warning(:importer, "metagame: skipped seed file #{path}: #{inspect(reason)}")
      end)

      Repo.transaction(fn -> insert_all!(format, definition_attrs, override_attrs) end)
      Log.info(:importer, "metagame: seeded #{length(definition_attrs)} #{format} definitions")
      load(format)
    end
  end

  defp seed_files(format) do
    format_dir = Path.join(@seed_dir, format)

    for subpath <- ["Archetypes", "Fallbacks"],
        dir = Path.join(format_dir, subpath),
        File.dir?(dir),
        file <- File.ls!(dir),
        Path.extname(file) == ".json",
        into: overrides_file(format_dir) do
      {"#{subpath}/#{file}", File.read!(Path.join(dir, file))}
    end
  end

  defp overrides_file(format_dir) do
    path = Path.join(format_dir, "color_overrides.json")

    if File.exists?(path) do
      %{"color_overrides.json" => File.read!(path)}
    else
      %{}
    end
  end

  defp insert_all!(format, definition_attrs, override_attrs) do
    Enum.each(definition_attrs, fn attrs ->
      attrs
      |> Map.merge(%{
        format: format,
        conditions: Definitions.wrap_entries(attrs.conditions),
        variants: Definitions.wrap_entries(attrs.variants),
        common_cards: Definitions.wrap_entries(attrs.common_cards)
      })
      |> then(&ArchetypeDefinition.changeset(%ArchetypeDefinition{}, &1))
      |> Repo.insert!()
    end)

    Enum.each(override_attrs, fn attrs ->
      attrs
      |> Map.put(:format, format)
      |> then(&ColorOverride.changeset(%ColorOverride{}, &1))
      |> Repo.insert!()
    end)
  end

  # ── Change detection ────────────────────────────────────────────────

  defp comparable(%Definitions{} = definitions) do
    %{
      archetypes: Enum.sort(definitions.archetypes),
      fallbacks: Enum.sort(definitions.fallbacks),
      land_overrides: definitions.land_overrides,
      nonland_overrides: definitions.nonland_overrides
    }
  end

  defp comparable_attrs(format, definition_attrs, override_attrs) do
    rows =
      Enum.map(definition_attrs, fn attrs ->
        struct!(
          ArchetypeDefinition,
          Map.merge(attrs, %{
            format: format,
            conditions: Definitions.wrap_entries(attrs.conditions),
            variants: Definitions.wrap_entries(attrs.variants),
            common_cards: Definitions.wrap_entries(attrs.common_cards)
          })
        )
      end)

    overrides =
      Enum.map(override_attrs, fn attrs ->
        struct!(ColorOverride, Map.put(attrs, :format, format))
      end)

    comparable(Definitions.build(format, rows, overrides))
  end
end
