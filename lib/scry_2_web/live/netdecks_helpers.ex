defmodule Scry2Web.NetdecksHelpers do
  @moduledoc "Pure helpers for `Scry2Web.NetdecksLive` (ADR-013)."

  alias Scry2Web.DeckRendering
  alias Scry2Web.DeckSearch

  # Presentation metadata per buildability status. `section` is the tier
  # heading in the catalog; `label` is the compact per-variant badge text;
  # `definition` and `ordering` are the tier subtitle — the ordering rule is
  # stated on the page (UIDR-017).
  @statuses %{
    buildable: %{
      label: "Buildable",
      section: "Buildable now",
      definition: "at least one list fully owned",
      ordering: "ordered by best finish",
      badge: "badge-soft badge-success",
      icon: "hero-check-circle",
      tone: "text-success",
      tone_dot: "bg-success"
    },
    craftable: %{
      label: "Craftable",
      section: "Craftable now",
      definition: "at least one list within current wildcards",
      ordering: "ordered by cheapest build",
      badge: "badge-soft badge-info",
      icon: "hero-sparkles",
      tone: "text-info",
      tone_dot: "bg-info"
    },
    short: %{
      label: "Short",
      section: "Within reach",
      definition: "missing wildcards",
      ordering: "ordered by cheapest build",
      badge: "badge-ghost",
      icon: "hero-arrow-trending-up",
      tone: "text-base-content/40",
      tone_dot: "bg-base-content/40"
    },
    incomplete: %{
      label: "Incomplete",
      section: "Not on MTGA",
      definition: "cards missing from MTGA — no wildcard count builds these",
      ordering: "ordered by best finish",
      badge: "badge-soft badge-warning",
      icon: "hero-exclamation-triangle",
      tone: "text-warning",
      tone_dot: "bg-warning"
    }
  }

  @doc "Relative time label (e.g. \"3 days ago\") — delegated to the shared helper."
  defdelegate relative_time(datetime), to: Scry2Web.LiveHelpers

  @doc "Status group order, cheapest/most-ready first; incomplete (never buildable) last."
  @spec status_order() :: [:buildable | :craftable | :short | :incomplete]
  def status_order, do: [:buildable, :craftable, :short, :incomplete]

  @doc "Presentation metadata (label, section heading, badge/icon classes) for a status."
  @spec status_meta(:buildable | :craftable | :short | :incomplete) :: map()
  def status_meta(status), do: Map.fetch!(@statuses, status)

  @doc "Whole-percent label for an owned fraction (0.0–1.0), e.g. \"82%\"."
  @spec format_owned_pct(float()) :: String.t()
  def format_owned_pct(fraction), do: "#{round(fraction * 100)}%"

  @doc """
  True when every maindeck card is owned. Fully-owned tiles omit the cost
  and percentage — "100%" next to a zero cost is dead information the
  Buildable-now section heading already carries.
  """
  @spec fully_owned?(map()) :: boolean()
  def fully_owned?(%{maindeck: %{owned_pct: owned_pct}}), do: owned_pct >= 1.0

  @doc """
  References on a deck that never resolved to an arena_id, as
  `[%{name, count}]` — enough to render a placeholder tile, since
  there's no `arena_id` to look up art or type by.
  """
  @spec unresolved_entries(map()) :: [%{name: String.t(), count: integer()}]
  def unresolved_entries(%{unresolved_cards: %{"cards" => cards}}) when is_list(cards) do
    # `||` is safe here — count is a numeric default, not a boolean field
    # (unlike the `false || fallback` trap this codebase has hit before).
    Enum.map(cards, fn card -> %{name: card["name"], count: card["count"] || 1} end)
  end

  def unresolved_entries(_deck), do: []

  @doc "Count of references on a deck that did not resolve to an arena_id."
  @spec unresolved_count(map()) :: non_neg_integer()
  def unresolved_count(deck), do: length(unresolved_entries(deck))

  @doc """
  A group's search facets (`Scry2Web.DeckSearch`): it answers to its
  archetype label and to every variant's deck name and source-provided
  archetype, and it plays the cards its variants play.
  """
  @spec search_facets(map()) :: DeckSearch.Facets.t()
  def search_facets(group) do
    variant_names =
      Enum.flat_map(group.variants, fn variant ->
        [variant.deck.name, variant.deck.archetype]
      end)

    %DeckSearch.Facets{names: [group.label | variant_names], card_keys: group.card_names}
  end

  @doc """
  Archetype suggestion candidates: one per distinct group label across all
  tiers; count sums the decklists under that label. Corpus-specific — the
  suggestion list stays at archetype granularity even though the query also
  matches individual deck names.
  """
  @spec archetype_candidates(map()) :: [DeckSearch.candidate()]
  def archetype_candidates(catalog) do
    [catalog.buildable, catalog.craftable, catalog.short, catalog.incomplete]
    |> Enum.concat()
    |> Enum.group_by(& &1.label)
    |> Enum.map(fn {label, groups} ->
      %{key: label, label: label, count: groups |> Enum.map(& &1.list_count) |> Enum.sum()}
    end)
  end

  @doc "The archetype group with this slug, across all tiers; nil when absent."
  @spec find_group(map(), String.t()) :: map() | nil
  def find_group(catalog, slug) do
    [catalog.buildable, catalog.craftable, catalog.short]
    |> Enum.concat()
    |> Enum.find(fn group -> group.slug == slug end)
  end

  @doc "Non-zero tally entries as {status, count} in buildable → craftable → short order."
  @spec tally_parts(map()) :: [{atom(), pos_integer()}]
  def tally_parts(tally) do
    for status <- status_order(), (count = Map.get(tally, status, 0)) > 0, do: {status, count}
  end

  @doc "The group's cheapest variant — the build the tile's cost line quotes."
  @spec cheapest_variant(map()) :: map()
  def cheapest_variant(%{variants: variants}) do
    Enum.min_by(variants, fn variant -> variant.result.sort_key end)
  end

  @doc """
  Medal tone for a finish label: gold for 1st, silver for the rest of the
  podium, neutral for any other rank; nil finish carries no medal.
  Playoff finishes render as bare ordinals ("2nd"), so exact matches suffice.
  """
  @spec medal_tone(String.t() | nil) :: :gold | :silver | :neutral | nil
  def medal_tone(nil), do: nil
  def medal_tone("1st"), do: :gold
  def medal_tone(finish) when finish in ["2nd", "3rd"], do: :silver
  def medal_tone(_finish), do: :neutral

  @doc ~s(Compact medal text: the finish's ordinal — "14th of 42" → "14th".)
  @spec medal_text(String.t() | nil) :: String.t() | nil
  def medal_text(nil), do: nil
  def medal_text(finish), do: finish |> String.split(" ") |> hd()

  @doc """
  The deck id to jump straight to when an archetype has exactly one variant —
  an archetype page with a single build is redundant, so the catalog links
  through to that build's detail page instead. Returns nil otherwise.
  """
  @spec sole_variant_deck_id(map()) :: integer() | nil
  def sole_variant_deck_id(%{variants: [%{deck: %{id: id}}]}), do: id
  def sole_variant_deck_id(_group), do: nil

  @doc """
  A variant's core deltas grouped for the chip strip (UIDR-017):
  `[{broad_type_label, [%{arena_id, delta, name, rarity, missing}]}]` in the
  canonical broad-type order, additions before cuts inside each section.

  `craft_by_arena_id` maps a card's `arena_id` to the copies the player is
  short of the variant's list (`needed − owned`); it drives the corner
  craft-a-wildcard pip on added chips. Cards absent from it default to 0.
  """
  @spec delta_sections([map()], %{optional(integer()) => map()}, %{
          optional(integer()) => integer()
        }) :: [{String.t(), [map()]}]
  def delta_sections(deltas, cards_by_arena_id, craft_by_arena_id) do
    deltas
    |> Enum.map(fn %{arena_id: arena_id, delta: delta} ->
      card = Map.get(cards_by_arena_id, arena_id)

      %{
        arena_id: arena_id,
        delta: delta,
        name: card_display_name(card, arena_id),
        rarity: card_rarity(card),
        missing: Map.get(craft_by_arena_id, arena_id, 0),
        section: card |> DeckRendering.type_label() |> DeckRendering.broad_type_label()
      }
    end)
    |> Enum.group_by(& &1.section)
    |> Enum.sort_by(fn {section, _entries} -> DeckRendering.broad_type_order(section) end)
    |> Enum.map(fn {section, entries} ->
      ordered = Enum.sort_by(entries, fn entry -> {-entry.delta, entry.name} end)
      {section, Enum.map(ordered, &Map.take(&1, [:arena_id, :delta, :name, :rarity, :missing]))}
    end)
  end

  defp card_display_name(%{name: name}, _arena_id) when is_binary(name), do: name
  defp card_display_name(_card, arena_id), do: "#" <> Integer.to_string(arena_id)

  defp card_rarity(%{rarity: rarity}) when is_binary(rarity), do: rarity
  defp card_rarity(_card), do: nil

  @doc """
  The browsable website behind an automated source's badge in the
  catalog strip, or nil for sources with nothing to visit (manual
  paste, local JSON). Lets the badge link through for manual browsing.
  """
  @spec source_site_url(String.t()) :: String.t() | nil
  def source_site_url("mtgo"), do: "https://www.mtgo.com/decklists"
  def source_site_url(_source_name), do: nil

  @doc """
  The source-provided archetype string, shown as a small badge only when
  it adds information — i.e. it exists and differs from the classified
  title already displayed.
  """
  @spec source_archetype_note(map(), String.t()) :: String.t() | nil
  def source_archetype_note(%{archetype: nil}, _label), do: nil

  def source_archetype_note(%{archetype: archetype}, label) do
    if String.downcase(archetype) == String.downcase(label), do: nil, else: archetype
  end

  @doc """
  Tile provenance subtitle: "1st · Standard Challenge 32 · Jun 26".
  Absent parts are omitted; nil provenance yields nil (no line, UIDR-010).
  """
  @spec tile_subtitle(map() | nil) :: String.t() | nil
  def tile_subtitle(nil), do: nil

  def tile_subtitle(provenance) do
    join_parts([
      provenance.finish,
      provenance.event_name,
      format_event_date(provenance.event_date)
    ])
  end

  @doc """
  Detail-header provenance line:
  "Venom01 — 1st · Standard Challenge 32 · Jun 26, 2026 · 7-2".
  Takes the `deck_detail` map (`deck` + `finish` + `record`); nil when the
  deck carries no provenance at all. The source link renders separately.
  """
  @spec detail_provenance(map()) :: String.t() | nil
  def detail_provenance(%{deck: deck, finish: finish, record: record}) do
    join_parts([
      pilot_finish(deck.pilot, finish),
      deck.event_name,
      format_event_date_long(deck.event_date),
      record
    ])
  end

  defp pilot_finish(nil, finish), do: finish
  defp pilot_finish(pilot, nil), do: pilot
  defp pilot_finish(pilot, finish), do: "#{pilot} — #{finish}"

  defp join_parts(parts) do
    case Enum.reject(parts, &is_nil/1) do
      [] -> nil
      present -> Enum.join(present, " · ")
    end
  end

  @doc ~s(Short event date for tiles: "Jun 26"; nil in, nil out.)
  @spec format_event_date(Date.t() | nil) :: String.t() | nil
  def format_event_date(nil), do: nil
  def format_event_date(date), do: Calendar.strftime(date, "%b %-d")

  @doc ~s(Long event date for the detail header: "Jun 26, 2026"; nil in, nil out.)
  @spec format_event_date_long(Date.t() | nil) :: String.t() | nil
  def format_event_date_long(nil), do: nil
  def format_event_date_long(date), do: Calendar.strftime(date, "%b %-d, %Y")

  @doc ~s(Link text for a source URL: host without "www." — "mtgo.com".)
  @spec source_host(String.t() | nil) :: String.t() | nil
  def source_host(nil), do: nil

  def source_host(url) do
    case URI.parse(url).host do
      nil -> nil
      host -> String.replace_prefix(host, "www.", "")
    end
  end

  # ── Import browser state (UIDR-011) ────────────────────────────────────

  @doc "Picker metadata for browsable source modules: `[%{name, module, formats}]`."
  @spec browse_source_options([module()]) :: [map()]
  def browse_source_options(source_modules) do
    Enum.map(source_modules, fn source_module ->
      %{
        name: source_module.source_name(),
        module: source_module,
        formats: source_module.formats()
      }
    end)
  end

  @doc """
  Fresh browse-pane state pointing at the first browsable source and its
  first format; nil when nothing is browsable (the Browse tab hides).
  """
  @spec initial_browse([map()]) :: map() | nil
  def initial_browse([]), do: nil

  def initial_browse([first_option | _rest]) do
    %{
      source: first_option.module,
      source_name: first_option.name,
      formats: first_option.formats,
      format: List.first(first_option.formats),
      events: nil,
      loading?: false,
      error: nil,
      selected: MapSet.new(),
      importing?: false,
      auto_fetch?: true
    }
  end

  @doc "Adds the url to the selection if absent, removes it if present."
  @spec toggle_selection(MapSet.t(), String.t()) :: MapSet.t()
  def toggle_selection(selected, url) do
    if MapSet.member?(selected, url) do
      MapSet.delete(selected, url)
    else
      MapSet.put(selected, url)
    end
  end

  @doc """
  Flash message for a batch of per-event import results
  (`[{:ok, %{ingested: n, ...}} | {:error, reason}]`).
  """
  @spec import_flash([{:ok, map()} | {:error, term()}]) :: String.t()
  def import_flash(results) do
    {ok_summaries, failures} = Enum.split_with(results, &match?({:ok, _summary}, &1))
    failed_count = length(failures)

    case {ok_summaries, failed_count} do
      {[], failed} ->
        "Couldn't import — #{pluralize(failed, "event")} failed."

      {summaries, failed} ->
        decks = summaries |> Enum.map(fn {:ok, summary} -> summary.ingested end) |> Enum.sum()

        base =
          "Imported #{pluralize(decks, "deck")} from #{pluralize(length(summaries), "event")}."

        if failed > 0 do
          base <> " #{pluralize(failed, "event")} failed."
        else
          base
        end
    end
  end

  defp pluralize(1, noun), do: "1 #{noun}"
  defp pluralize(count, noun), do: "#{count} #{noun}s"

  @doc ~s(Matrix cell text for a nonzero copy delta: "+2", "−1" [U+2212].)
  @spec matrix_delta_label(integer()) :: String.t()
  def matrix_delta_label(delta) when delta > 0, do: "+#{delta}"
  def matrix_delta_label(delta) when delta < 0, do: "−#{-delta}"

  @doc ~s(Matrix footer magnitude: "±14", or nil for zero so the cell stays empty.)
  @spec matrix_magnitude_label(non_neg_integer()) :: String.t() | nil
  def matrix_magnitude_label(0), do: nil
  def matrix_magnitude_label(magnitude), do: "±#{magnitude}"

  @doc """
  Truncated page-number list for pagination controls: first page, last
  page, and the current page's immediate neighbours, with `:ellipsis`
  marking any gap skipped in between. Below 8 pages every page is kept —
  truncation is only worth the extra visual noise once the strip would
  otherwise overflow.
  """
  @spec page_window(pos_integer(), pos_integer()) :: [pos_integer() | :ellipsis]
  def page_window(_page, total_pages) when total_pages <= 7, do: Enum.to_list(1..total_pages)

  def page_window(page, total_pages) do
    [1, total_pages, max(page - 1, 1), page, min(page + 1, total_pages)]
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce([], fn
      page_number, [] ->
        [page_number]

      page_number, [previous | _] = acc when page_number - previous > 1 ->
        [page_number, :ellipsis | acc]

      page_number, acc ->
        [page_number | acc]
    end)
    |> Enum.reverse()
  end
end
