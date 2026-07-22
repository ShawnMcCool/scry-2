defmodule Scry2Web.NetdecksHelpers do
  @moduledoc "Pure helpers for `Scry2Web.NetdecksLive` (ADR-013)."

  alias Scry2Web.DeckRendering

  @order [common: "c", uncommon: "u", rare: "r", mythic: "m"]
  @rarity_order [:common, :uncommon, :rare, :mythic]

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
    }
  }

  @doc "Relative time label (e.g. \"3 days ago\") — delegated to the shared helper."
  defdelegate relative_time(datetime), to: Scry2Web.LiveHelpers

  @doc "Status group order, cheapest/most-ready first."
  @spec status_order() :: [:buildable | :craftable | :short]
  def status_order, do: [:buildable, :craftable, :short]

  @doc "Presentation metadata (label, section heading, badge/icon classes) for a status."
  @spec status_meta(:buildable | :craftable | :short) :: map()
  def status_meta(status), do: Map.fetch!(@statuses, status)

  @doc """
  Non-zero wildcard-cost entries as `{rarity, count}` in common→mythic order,
  for rendering rarity-coloured pips.
  """
  @spec cost_pips(map()) :: [{atom(), integer()}]
  def cost_pips(cost) do
    for rarity <- @rarity_order, (count = Map.get(cost, rarity, 0)) > 0, do: {rarity, count}
  end

  @doc "True if a cost/shortfall map has any non-zero rarity."
  @spec any_cost?(map()) :: boolean()
  def any_cost?(cost), do: cost_pips(cost) != []

  @doc ~s(Compact wildcard-cost label, e.g. "2u 1r". Returns "—" when zero.)
  @spec format_cost(map()) :: String.t()
  def format_cost(cost) do
    parts =
      for {rarity, suffix} <- @order,
          (count = Map.get(cost, rarity, 0)) > 0,
          do: "#{count}#{suffix}"

    case parts do
      [] -> "—"
      _ -> Enum.join(parts, " ")
    end
  end

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
  Per-card ownership state for styling a decklist row:
  `:free` (basic land), `:owned` (have all needed), `:missing` (own none),
  `:partial` (own some but not all).
  """
  @spec card_row_state(map()) :: :free | :owned | :missing | :partial
  def card_row_state(%{free?: true}), do: :free
  def card_row_state(%{missing: 0}), do: :owned
  def card_row_state(%{owned: 0}), do: :missing
  def card_row_state(_row), do: :partial

  @doc "Text-colour class for a decklist row's ownership state."
  @spec card_row_tone(:free | :owned | :missing | :partial) :: String.t()
  def card_row_tone(:free), do: "text-base-content/30"
  def card_row_tone(:owned), do: "text-success"
  def card_row_tone(:missing), do: "text-warning"
  def card_row_tone(:partial), do: "text-base-content/60"

  @doc """
  The deck view's `count_entry` function for a netdeck's ownership overlay
  (UIDR-015/017): counts render in the gutter rail (or splay badge), toned
  by ownership, with the ownership tooltip. Blank means one fully-owned
  copy; cards with missing copies always show their count. Cards without
  an ownership row fall back to the plain count.
  """
  @spec ownership_count_entry(%{optional(integer()) => map()}) :: (map() -> map() | nil)
  def ownership_count_entry(rows_by_arena_id) do
    fn card ->
      case Map.get(rows_by_arena_id, card.arena_id) do
        nil ->
          case count_label(card.count) do
            nil -> nil
            label -> %{label: label, class: nil, title: nil}
          end

        %{free?: true} = row ->
          %{
            label: to_string(card.count),
            class: "text-base-content/30",
            title: ownership_title(row)
          }

        %{missing: missing} = row when missing > 0 ->
          %{
            label: to_string(card.count),
            class: row |> card_row_state() |> card_row_tone(),
            title: ownership_title(row)
          }

        row ->
          case count_label(card.count) do
            nil -> nil
            label -> %{label: label, class: "text-success", title: ownership_title(row)}
          end
      end
    end
  end

  defp count_label(count) when is_integer(count) and count > 1, do: to_string(count)
  defp count_label(_count), do: nil

  @doc """
  Indexes decklist rows (main + sideboard) by arena_id for the ownership
  overlay on the standard deck composition. Rows without a resolved
  arena_id are skipped — they can't be matched to a rendered card.
  """
  @spec rows_by_arena_id([map()], [map()]) :: %{integer() => map()}
  def rows_by_arena_id(main_rows, side_rows) do
    (main_rows ++ side_rows)
    |> Enum.filter(&is_integer(&1.arena_id))
    |> Map.new(fn row -> {row.arena_id, row} end)
  end

  @doc """
  Row tint for the text deck listing: warning tone when the player is
  missing copies of the card, nil (default color) otherwise.
  """
  @spec missing_row_class(map() | nil) :: String.t() | nil
  def missing_row_class(%{missing: missing}) when missing > 0, do: "text-warning"
  def missing_row_class(_row), do: nil

  @doc "Tooltip text describing a decklist row's ownership, or nil without a row."
  @spec ownership_title(map() | nil) :: String.t() | nil
  def ownership_title(nil), do: nil
  def ownership_title(%{free?: true} = row), do: "#{row.name} — basic land"
  def ownership_title(row), do: "#{row.name} — #{row.owned}/#{row.needed} owned"

  @doc "Count of references on a deck that did not resolve to an arena_id."
  @spec unresolved_count(map()) :: non_neg_integer()
  def unresolved_count(%{unresolved_cards: %{"cards" => cards}}) when is_list(cards),
    do: length(cards)

  def unresolved_count(_deck), do: 0

  @doc """
  True if the archetype group's label, or any variant's deck name or
  source-provided archetype, contains `query` (case-insensitive). Empty
  query matches all.
  """
  @spec match_search?(map(), String.t()) :: boolean()
  def match_search?(_group, ""), do: true

  def match_search?(group, query) do
    query_lower = String.downcase(query)

    contains?(group.label, query_lower) or
      Enum.any?(group.variants, fn variant ->
        contains?(variant.deck.name, query_lower) or
          contains?(variant.deck.archetype, query_lower)
      end)
  end

  defp contains?(nil, _query_lower), do: false
  defp contains?(value, query_lower), do: String.contains?(String.downcase(value), query_lower)

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

  @doc "The player's wildcard pool as {rarity, count} in common → mythic order."
  @spec wildcard_balances(map()) :: [{atom(), integer()}]
  def wildcard_balances(wildcards) do
    Enum.map(@rarity_order, fn rarity -> {rarity, Map.get(wildcards, rarity, 0)} end)
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
