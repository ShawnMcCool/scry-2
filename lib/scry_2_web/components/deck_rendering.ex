defmodule Scry2Web.DeckRendering do
  @moduledoc """
  The deck rendering engine: every card-list display in the app is a
  parameterization of one pipeline, not a bespoke template.

  ## Pipeline

  1. **Normalize** — `cards/1` accepts any card-list snapshot shape
     (`%{"cards" => [...]}`, a list of card maps, a bare list of
     arena_ids, or nil) and yields `[%{arena_id, count}]`.
  2. **Resolve** — entries join the card reference (`cards_by_arena_id`)
     for name, type, and mana value.
  3. **Section** — `sections/3` splits resolved entries into labeled
     sections per `ViewSpec.group_by`, applying `ViewSpec.piling`
     (merge duplicates vs. one entry per copy) and canonical ordering.
  4. **Present** — `deck_view/1` renders the sections per
     `ViewSpec.display` and `ViewSpec.layout`.

  ## Composing views

      <.deck_view_group id="deck">
        <.deck_view
          id="deck-grid"
          spec={%ViewSpec{group_by: :mana_value, display: :images, layout: :columns}}
          cards={@deck.current_main_deck}
          cards_by_arena_id={@cards_by_arena_id}
          cached_ids={@cached_card_ids}
        />
      </.deck_view_group>

  Pages compose any number of views. The three deck pages share the
  `standard_composition/1` preset — mana curve chart, text columns by
  type (with a Sideboard column), image stacks by mana value, and a
  sideboard splay row.

  `deck_view_group/1` carries the `DeckView` JS hook that harmonizes
  card sizes across the views inside it (`:row` splay cards match the
  `:columns` grid width). `:columns` and `:row` views must render
  inside a group.

  The optional `card_overlay` slot replaces the default count badge on
  every card image with caller-specific annotation (e.g. the netdeck
  ownership markers). It receives the resolved card and renders inside
  the card's relatively-positioned wrapper.
  """

  use Phoenix.Component

  import Scry2Web.CardComponents
  import Scry2Web.CoreComponents, only: [kind_label: 1]

  alias Scry2.Cards.ImageCache
  alias Scry2Web.DeckRendering.ViewSpec

  # ── Components ──────────────────────────────────────────────────────

  @doc """
  Renders one view of a card list per its `ViewSpec`.

  Provide entries via `cards` (a snapshot, grouped per the spec) and/or
  `sections` (pre-labeled `{label, snapshot}` pairs appended after the
  grouped sections — how the text view gains its Sideboard column).
  Renders nothing when there are no entries.
  """
  attr :id, :string, required: true
  attr :spec, ViewSpec, required: true
  attr :cards, :any, default: nil
  attr :sections, :list, default: [], doc: "Pre-labeled `{label, snapshot}` pairs."
  attr :cards_by_arena_id, :map, required: true
  attr :cached_ids, :any, default: nil
  attr :title, :string, default: nil, doc: "Optional kind_label heading inside the view."

  attr :card_class, :any,
    default: nil,
    doc: "Optional `resolved_card -> class` function; tints text-view rows (e.g. missing cards)."

  slot :card_overlay, doc: "Per-card annotation replacing the default count badge."

  def deck_view(assigns) do
    resolved_sections =
      sections(assigns.cards, assigns.spec, assigns.cards_by_arena_id) ++
        Enum.map(assigns.sections, fn {label, snapshot} ->
          {label, resolved_cards(snapshot, assigns.spec, assigns.cards_by_arena_id)}
        end)

    resolved_sections = Enum.reject(resolved_sections, fn {_, cards} -> cards == [] end)
    assigns = assign(assigns, :resolved_sections, resolved_sections)

    ~H"""
    <%= case {@resolved_sections, @spec.display, @spec.layout} do %>
      <% {[], _, _} -> %>
      <% {_, :text, _} -> %>
        <.text_view {view_assigns(assigns)} />
      <% {_, :images, :columns} -> %>
        <.columns_view {view_assigns(assigns)} />
      <% {_, :images, :row} -> %>
        <.row_view {view_assigns(assigns)} />
      <% {_, :images, :wrap} -> %>
        <.wrap_view {view_assigns(assigns)} />
    <% end %>
    """
  end

  defp view_assigns(assigns),
    do:
      Map.take(assigns, [
        :id,
        :spec,
        :resolved_sections,
        :cached_ids,
        :title,
        :card_overlay,
        :card_class
      ])

  @doc """
  Wrapper carrying the `DeckView` JS hook that coordinates card sizing
  across the views inside it: `:row` splay cards adopt the `:columns`
  grid's column width, and the splay spreads to the grid's width. Wrap
  every `:columns` or `:row` view in a group — a lone `:row` view still
  needs the group for its overlap layout.
  """
  attr :id, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def deck_view_group(assigns) do
    ~H"""
    <div id={@id} phx-hook="DeckView" class={@class}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The standard deck composition — the app's default way to render a
  deck, as established on the deck detail page: mana curve chart, text
  card list in type columns (with a Sideboard column), main-deck image
  stacks by mana value, and the sideboard as a splayed row.
  """
  attr :id, :string, required: true
  attr :main_deck, :any, required: true
  attr :sideboard, :any, default: nil
  attr :cards_by_arena_id, :map, required: true
  attr :cached_ids, :any, default: nil

  attr :show_curve, :boolean,
    default: true,
    doc: "Set false when the page places `mana_curve_chart/1` elsewhere."

  attr :card_class, :any,
    default: nil,
    doc: "Forwarded to the text view — see `deck_view/1`."

  slot :card_overlay, doc: "Forwarded to every image view — see `deck_view/1`."

  def standard_composition(assigns) do
    assigns =
      assign(assigns,
        main_total: card_count(assigns.main_deck),
        side_total: card_count(assigns.sideboard),
        text_spec: %ViewSpec{group_by: :type, display: :text},
        grid_spec: %ViewSpec{group_by: :mana_value, display: :images, layout: :columns},
        row_spec: %ViewSpec{display: :images, layout: :row}
      )

    ~H"""
    <div :if={not empty?(@main_deck, @sideboard)}>
      <%!-- Mana Curve — half width, space reserved for future chart --%>
      <div :if={@show_curve} class="w-1/2">
        <.mana_curve_chart
          id={"#{@id}-curve"}
          cards={@main_deck}
          cards_by_arena_id={@cards_by_arena_id}
        />
      </div>

      <div class={if @show_curve, do: "mt-8"}>
        <.deck_view
          id={"#{@id}-list"}
          spec={@text_spec}
          cards={@main_deck}
          sections={if @side_total > 0, do: [{"Sideboard", @sideboard}], else: []}
          cards_by_arena_id={@cards_by_arena_id}
          cached_ids={@cached_ids}
          card_class={@card_class}
        />
      </div>

      <.kind_label class="mt-8">main deck ({@main_total})</.kind_label>

      <.deck_view_group id={"#{@id}-view"} class="mt-3">
        <.deck_view
          id={"#{@id}-grid"}
          spec={@grid_spec}
          cards={@main_deck}
          cards_by_arena_id={@cards_by_arena_id}
          cached_ids={@cached_ids}
        >
          <:card_overlay :let={card} :if={@card_overlay != []}>
            {render_slot(@card_overlay, card)}
          </:card_overlay>
        </.deck_view>
        <.deck_view
          :if={@side_total > 0}
          id={"#{@id}-side"}
          spec={@row_spec}
          cards={@sideboard}
          cards_by_arena_id={@cards_by_arena_id}
          cached_ids={@cached_ids}
          title={"sideboard (#{@side_total})"}
        >
          <:card_overlay :let={card} :if={@card_overlay != []}>
            {render_slot(@card_overlay, card)}
          </:card_overlay>
        </.deck_view>
      </.deck_view_group>
    </div>
    """
  end

  @doc """
  The mana curve as an ECharts bar chart (non-land mana values 0–7+).
  Part of the standard composition; place it anywhere by rendering it
  standalone and passing `show_curve={false}` to the composition.
  """
  attr :id, :string, required: true
  attr :cards, :any, required: true
  attr :cards_by_arena_id, :map, required: true
  attr :class, :any, default: "w-full rounded-lg bg-base-200"
  attr :height, :string, default: "5rem"

  def mana_curve_chart(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Chart"
      data-chart-type="curve"
      data-series={curve_series(@cards, @cards_by_arena_id)}
      class={@class}
      style={"height: #{@height}"}
    />
    """
  end

  # ── Display: text ───────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :spec, ViewSpec, required: true
  attr :resolved_sections, :list, required: true
  attr :cached_ids, :any, default: nil
  attr :title, :string, default: nil
  attr :card_overlay, :list, default: []
  attr :card_class, :any, default: nil

  defp text_view(assigns) do
    ~H"""
    <div>
      <.kind_label :if={@title}>{@title}</.kind_label>
      <div class="flex flex-wrap gap-8">
        <div :for={{{label, cards}, section_idx} <- Enum.with_index(@resolved_sections)}>
          <h3
            :if={label}
            class="flex items-center gap-2 text-xs font-medium text-base-content/40 uppercase tracking-wide mb-1"
          >
            <span class="w-4 shrink-0" />{label} ({section_total(cards)})
          </h3>
          <div class="space-y-0.5">
            <div
              :for={{card, card_idx} <- Enum.with_index(cards)}
              id={"#{@id}-s#{section_idx}-#{card_idx}-#{card.arena_id}"}
              class={[
                "flex items-baseline gap-2 text-sm py-0.5 cursor-default",
                @card_class && @card_class.(card)
              ]}
              phx-hook={if image_cached?(@cached_ids, card.arena_id), do: "CardHover"}
              data-card-src={ImageCache.url_for(card.arena_id)}
              data-card-alt={card.name}
            >
              <span class="text-base-content/50 w-4 text-right tabular-nums shrink-0">
                {card.count}
              </span>
              <span>{card.name}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Display: images, layout: columns ────────────────────────────────

  attr :id, :string, required: true
  attr :spec, ViewSpec, required: true
  attr :resolved_sections, :list, required: true
  attr :cached_ids, :any, default: nil
  attr :title, :string, default: nil
  attr :card_overlay, :list, default: []

  defp columns_view(assigns) do
    ~H"""
    <div>
      <.kind_label :if={@title}>{@title}</.kind_label>
      <div class="flex gap-3 items-start" data-deck-grid>
        <div
          :for={{{label, cards}, section_idx} <- Enum.with_index(@resolved_sections)}
          class="flex-1 min-w-0 flex flex-col items-center"
        >
          <p :if={label} class="text-xs text-base-content/30 mb-1">{label}</p>
          <div
            class="relative w-full"
            style={"aspect-ratio: #{stack_aspect_ratio(length(cards), @spec.splay_depth)}"}
          >
            <div
              :for={{card, card_idx} <- Enum.with_index(cards)}
              class="absolute w-full left-0"
              style={"top: #{stack_top_percent(card_idx, length(cards), @spec.splay_depth)}%; z-index: #{card_idx}"}
            >
              <.card_image
                id={"#{@id}-s#{section_idx}-#{card_idx}-#{card.arena_id}"}
                arena_id={card.arena_id}
                name={card.name}
                class="w-full"
                cached_ids={@cached_ids}
              />
              <.count_badge card={card} spec={@spec} position="top-1 right-1" overlay={@card_overlay} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Display: images, layout: row ────────────────────────────────────

  attr :id, :string, required: true
  attr :spec, ViewSpec, required: true
  attr :resolved_sections, :list, required: true
  attr :cached_ids, :any, default: nil
  attr :title, :string, default: nil
  attr :card_overlay, :list, default: []

  defp row_view(assigns) do
    assigns = assign(assigns, :cards, Enum.flat_map(assigns.resolved_sections, &elem(&1, 1)))

    ~H"""
    <div class="mt-8" data-sideboard-splay>
      <.kind_label :if={@title} class="mb-3">{@title}</.kind_label>
      <div data-splay-container class="flex items-end pb-4">
        <div
          :for={{card, card_idx} <- Enum.with_index(@cards)}
          class="relative flex-shrink-0"
          style={"width: #{@spec.card_width}"}
          data-splay-card
        >
          <.card_image
            id={"#{@id}-#{card_idx}-#{card.arena_id}"}
            arena_id={card.arena_id}
            name={card.name}
            class="w-full"
            cached_ids={@cached_ids}
          />
          <.count_badge card={card} spec={@spec} position="bottom-1 left-1" overlay={@card_overlay} />
        </div>
      </div>
    </div>
    """
  end

  # ── Display: images, layout: wrap ───────────────────────────────────

  attr :id, :string, required: true
  attr :spec, ViewSpec, required: true
  attr :resolved_sections, :list, required: true
  attr :cached_ids, :any, default: nil
  attr :title, :string, default: nil
  attr :card_overlay, :list, default: []

  defp wrap_view(assigns) do
    ~H"""
    <div>
      <.kind_label :if={@title} class="mb-3">{@title}</.kind_label>
      <div class="flex flex-wrap gap-8">
        <div :for={{{label, cards}, section_idx} <- Enum.with_index(@resolved_sections)}>
          <div
            :if={label}
            class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-2"
          >
            {label} ({section_total(cards)})
          </div>
          <div class="flex gap-1 flex-wrap">
            <div
              :for={{card, card_idx} <- Enum.with_index(cards)}
              class="relative"
              style={"width: #{@spec.card_width}"}
            >
              <.card_image
                id={"#{@id}-s#{section_idx}-#{card_idx}-#{card.arena_id}"}
                arena_id={card.arena_id}
                name={card.name}
                class="w-full"
                cached_ids={@cached_ids}
              />
              <.count_badge card={card} spec={@spec} position="top-1 right-1" overlay={@card_overlay} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # The default per-card annotation: a count badge for piled views. An
  # overlay slot replaces it; spread views carry no badge (each copy is
  # its own card).
  attr :card, :map, required: true
  attr :spec, ViewSpec, required: true
  attr :position, :string, required: true
  attr :overlay, :list, required: true

  defp count_badge(%{overlay: [_ | _]} = assigns) do
    ~H"""
    {render_slot(@overlay, @card)}
    """
  end

  defp count_badge(%{spec: %ViewSpec{piling: :spread}} = assigns) do
    ~H""
  end

  defp count_badge(assigns) do
    ~H"""
    <span class={[
      "absolute min-w-5 text-center rounded bg-black/70 px-1 text-xs font-bold text-white pointer-events-none",
      @position
    ]}>
      {@card.count}
    </span>
    """
  end

  # ── Snapshot primitives ─────────────────────────────────────────────

  @typedoc """
  A card-list snapshot: `%{"cards" => [...]}`, a list of card maps
  (string or atom keys), a bare list of arena_ids, or nil.
  """
  @type snapshot :: map() | list() | nil

  @doc "Card entries of a snapshot as `[%{arena_id, count}]`, any input shape."
  @spec cards(snapshot()) :: [%{arena_id: integer() | nil, count: integer()}]
  def cards(%{"cards" => card_list}) when is_list(card_list),
    do: Enum.map(card_list, &normalize_card/1)

  def cards(card_list) when is_list(card_list), do: Enum.map(card_list, &normalize_card/1)
  def cards(_), do: []

  @doc "All arena_ids referenced by a snapshot."
  @spec arena_ids(snapshot()) :: [integer()]
  def arena_ids(snapshot) do
    snapshot |> cards() |> Enum.map(& &1.arena_id) |> Enum.filter(&is_integer/1)
  end

  @doc "Total card count of a snapshot."
  @spec card_count(snapshot()) :: non_neg_integer()
  def card_count(snapshot) do
    snapshot |> cards() |> Enum.map(& &1.count) |> Enum.sum()
  end

  @doc "True when neither snapshot has any cards."
  @spec empty?(snapshot(), snapshot()) :: boolean()
  def empty?(main_deck, sideboard), do: cards(main_deck) == [] and cards(sideboard) == []

  # ── Sectioning ──────────────────────────────────────────────────────

  @doc """
  Splits a snapshot into labeled sections per the spec's `group_by` and
  `piling`. Returns `[{label, [resolved_card]}]` — sections always in
  canonical order, cards within a section per the spec's `order`;
  `group_by: :none` yields a single `{nil, cards}` section. Each
  resolved card is `%{arena_id, count, name, type, mana_value, cmc_key}`.
  """
  @spec sections(snapshot(), ViewSpec.t(), map()) :: [{String.t() | nil, list()}]
  def sections(snapshot, %ViewSpec{} = spec, cards_by_arena_id) do
    resolved = resolve(snapshot, spec, cards_by_arena_id)

    case {resolved, spec.group_by} do
      {[], _} ->
        []

      {resolved, :none} ->
        [{nil, order_cards(resolved, spec, &{&1.mana_value, &1.name})}]

      {resolved, :type} ->
        resolved
        |> Enum.group_by(& &1.type)
        |> Enum.sort_by(fn {type, _} -> type_order(type) end)
        |> Enum.map(fn {type, group} ->
          {type, order_cards(group, spec, &{&1.mana_value, &1.name})}
        end)

      {resolved, :broad_type} ->
        resolved
        |> Enum.group_by(&broad_type_label(&1.type))
        |> Enum.sort_by(fn {label, _} -> broad_type_order(label) end)
        |> Enum.map(fn {label, group} ->
          {label, order_cards(group, spec, &{&1.mana_value, &1.name})}
        end)

      {resolved, :mana_value} ->
        resolved
        |> Enum.group_by(& &1.cmc_key)
        |> Enum.sort_by(fn {cmc_key, _} -> cmc_key end)
        |> Enum.map(fn {cmc_key, group} ->
          {cmc_label(cmc_key), order_cards(group, spec, & &1.name)}
        end)
    end
  end

  @doc """
  Resolves and piles a snapshot into a flat card list ordered per the
  spec — one pre-labeled section's worth of cards.
  """
  @spec resolved_cards(snapshot(), ViewSpec.t(), map()) :: list()
  def resolved_cards(snapshot, %ViewSpec{} = spec, cards_by_arena_id) do
    snapshot
    |> resolve(spec, cards_by_arena_id)
    |> order_cards(spec, &{&1.mana_value, &1.name})
  end

  # ── Mana curve ──────────────────────────────────────────────────────

  @doc """
  JSON-encoded series for the mana curve ECharts bar chart. Lands are
  excluded. Format: `[[cmc_label, count], ...]` for CMC 0–7+.
  """
  @spec curve_series(snapshot(), map()) :: String.t()
  def curve_series(main_deck, cards_by_arena_id) do
    curve = mana_curve(main_deck, cards_by_arena_id)

    0..7
    |> Enum.map(fn mana_value ->
      label = if mana_value >= 7, do: "7+", else: "#{mana_value}"
      [label, Map.get(curve, mana_value, 0)]
    end)
    |> Jason.encode!()
  end

  @doc """
  Mana curve of a snapshot as `%{mana_value => total_count}`, lands
  excluded, mana values capped at 7.
  """
  @spec mana_curve(snapshot(), map()) :: %{non_neg_integer() => pos_integer()}
  def mana_curve(snapshot, cards_by_arena_id) do
    snapshot
    |> cards()
    |> Enum.reduce(%{}, fn card, curve ->
      card_data = Map.get(cards_by_arena_id, card.arena_id)

      if land?(card_data) do
        curve
      else
        mana_value = min((card_data && card_data.mana_value) || 0, 7)
        Map.update(curve, mana_value, card.count, &(&1 + card.count))
      end
    end)
  end

  # ── Card names and types ────────────────────────────────────────────

  @doc "Returns a card name by arena_id from the cards lookup map, or a fallback."
  @spec card_name(integer() | nil, map()) :: String.t()
  def card_name(nil, _), do: "Unknown"

  def card_name(arena_id, cards_by_arena_id) do
    case Map.get(cards_by_arena_id, arena_id) do
      nil -> "#{arena_id}"
      card -> card.name
    end
  end

  @doc "Display type label (Creatures, Instants, …) for a card lookup entry."
  @spec type_label(map() | nil) :: String.t()
  def type_label(nil), do: "Unknown"

  def type_label(card_data) do
    types = card_data.types || ""

    cond do
      String.contains?(types, "Creature") -> "Creatures"
      String.contains?(types, "Planeswalker") -> "Planeswalkers"
      String.contains?(types, "Instant") -> "Instants"
      String.contains?(types, "Sorcery") -> "Sorceries"
      String.contains?(types, "Enchantment") -> "Enchantments"
      String.contains?(types, "Artifact") -> "Artifacts"
      String.contains?(types, "Land") -> "Lands"
      true -> "Other"
    end
  end

  @doc "Canonical sort position of a display type label."
  @spec type_order(String.t()) :: non_neg_integer()
  def type_order("Creatures"), do: 0
  def type_order("Planeswalkers"), do: 1
  def type_order("Instants"), do: 2
  def type_order("Sorceries"), do: 3
  def type_order("Enchantments"), do: 4
  def type_order("Artifacts"), do: 5
  def type_order("Lands"), do: 6
  def type_order(_), do: 7

  @doc """
  Condensed type vocabulary used by the draft pool: Creatures,
  Instants & Sorceries, Artifacts & Enchantments, Lands, Other.
  Takes a `type_label/1` result.
  """
  @spec broad_type_label(String.t()) :: String.t()
  def broad_type_label("Creatures"), do: "Creatures"
  def broad_type_label(label) when label in ["Instants", "Sorceries"], do: "Instants & Sorceries"

  def broad_type_label(label) when label in ["Artifacts", "Enchantments"],
    do: "Artifacts & Enchantments"

  def broad_type_label("Lands"), do: "Lands"
  def broad_type_label(_), do: "Other"

  @doc "Canonical sort position of a broad type label."
  @spec broad_type_order(String.t()) :: non_neg_integer()
  def broad_type_order("Creatures"), do: 0
  def broad_type_order("Instants & Sorceries"), do: 1
  def broad_type_order("Artifacts & Enchantments"), do: 2
  def broad_type_order("Lands"), do: 3
  def broad_type_order(_), do: 4

  # ── Stack layout math ───────────────────────────────────────────────
  #
  # `:columns` stacks are fully responsive: CSS aspect-ratio sizes the
  # container, percentage offsets place the cards. No JS measurement.

  @doc """
  CSS aspect-ratio value for a stack of `n` cards where each overlapped
  card reveals `splay_depth` of its height.
  """
  @spec stack_aspect_ratio(non_neg_integer(), float()) :: String.t()
  def stack_aspect_ratio(0, _splay_depth), do: "1"
  def stack_aspect_ratio(1, _splay_depth), do: "488 / 680"

  def stack_aspect_ratio(stack_size, splay_depth) do
    height_factor = (stack_size - 1) * splay_depth + 1.0
    "488 / #{Float.round(680 * height_factor, 1)}"
  end

  @doc """
  Top offset of a stacked card as a percentage of the container height.
  Card at index 0 → 0%, subsequent cards spaced by `splay_depth`.
  """
  @spec stack_top_percent(non_neg_integer(), pos_integer(), float()) :: float()
  def stack_top_percent(0, _stack_size, _splay_depth), do: 0.0

  def stack_top_percent(index, stack_size, splay_depth) do
    height_factor = (stack_size - 1) * splay_depth + 1.0
    Float.round(index * splay_depth / height_factor * 100, 2)
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp normalize_card(arena_id) when is_integer(arena_id), do: %{arena_id: arena_id, count: 1}

  defp normalize_card(card) do
    %{
      arena_id: to_int(card["arena_id"] || card[:arena_id]),
      count: to_int(card["count"] || card[:count]) || 1
    }
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)
  defp to_int(_), do: nil

  # Resolves snapshot entries against the card lookup, then applies the
  # spec's piling: `:piled` merges same-name entries (alt-art prints
  # share a name but have distinct arena_ids; earliest arena_id wins for
  # image lookups); `:spread` expands counts into individual copies.
  defp resolve(snapshot, %ViewSpec{piling: piling}, cards_by_arena_id) do
    resolved =
      snapshot
      |> cards()
      |> Enum.map(fn card ->
        card_data = Map.get(cards_by_arena_id, card.arena_id)

        %{
          arena_id: card.arena_id,
          count: card.count,
          name: card_name(card.arena_id, cards_by_arena_id),
          type: type_label(card_data),
          mana_value: (card_data && card_data.mana_value) || 99,
          cmc_key: cmc_key(card_data)
        }
      end)

    case piling do
      :piled ->
        merge_by_name(resolved)

      :spread ->
        Enum.flat_map(resolved, fn card -> List.duplicate(%{card | count: 1}, card.count) end)
    end
  end

  defp merge_by_name(resolved_cards) do
    resolved_cards
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {_name, group} ->
      total = group |> Enum.map(& &1.count) |> Enum.sum()
      first = List.first(group)
      %{first | count: total}
    end)
  end

  defp order_cards(cards, %ViewSpec{order: :natural}, _sort_key), do: cards
  defp order_cards(cards, _spec, sort_key), do: Enum.sort_by(cards, sort_key)

  defp section_total(cards), do: Enum.sum(Enum.map(cards, & &1.count))

  defp land?(nil), do: false
  defp land?(card_data), do: String.contains?(card_data.types || "", "Land")

  # CMC key: integer 0–7 for spells (7 = "7+"), 8 for lands (sort last)
  defp cmc_key(nil), do: 0

  defp cmc_key(card_data),
    do: if(land?(card_data), do: 8, else: min(card_data.mana_value || 0, 7))

  defp cmc_label(8), do: "Land"
  defp cmc_label(7), do: "7+"
  defp cmc_label(n), do: "#{n}"

  # Mirrors CardComponents.resolve_cached/1 for the text-list hover rows,
  # which attach CardHover directly rather than through <.card_image>.
  defp image_cached?(%{full: full}, arena_id), do: MapSet.member?(full, arena_id)
  defp image_cached?(_, arena_id), do: ImageCache.cached?(arena_id, :full)
end
