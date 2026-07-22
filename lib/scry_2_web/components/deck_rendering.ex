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

  Piled counts render per `ViewSpec.count_placement`: a `:badge` pill
  overlaid on the card image, (in `:columns` stacks) a `:gutter` rail
  reserved beside the image so no printed card information is ever
  covered, or `:none` for callers that draw their own counts — see
  `count_presentation/1` and UIDR-015.

  The optional `card_overlay` slot adds caller-specific annotation to
  every card image (e.g. the netdeck ownership wash, draft pick rings).
  It receives the resolved card, renders inside the card's
  relatively-positioned wrapper, and never affects count presentation.

  The optional `count_entry` function customizes how a card's count
  renders wherever the spec places it (gutter rail or badge pill):
  `resolved_card -> %{label, class, title} | nil` — nil hides the
  count. Omit it for the default presentation.
  """

  use Phoenix.Component

  import Scry2Web.CardComponents
  import Scry2Web.CoreComponents, only: [kind_label: 1, icon: 1]

  alias Scry2.Cards.ImageCache
  alias Scry2Web.DeckRendering.CompositionPrefs
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

  attr :count_entry, :any,
    default: nil,
    doc: "Optional `resolved_card -> %{label, class, title} | nil` function customizing counts."

  slot :card_overlay, doc: "Additive per-card annotation (never affects count presentation)."

  def deck_view(assigns) do
    resolved_sections =
      sections(assigns.cards, assigns.spec, assigns.cards_by_arena_id) ++
        Enum.map(assigns.sections, fn {label, snapshot} ->
          {label, resolved_cards(snapshot, assigns.spec, assigns.cards_by_arena_id)}
        end)

    resolved_sections = Enum.reject(resolved_sections, fn {_, cards} -> cards == [] end)

    assigns =
      assigns
      |> assign(:resolved_sections, resolved_sections)
      |> assign(:count_presentation, count_presentation(assigns.spec))

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
        :count_presentation,
        :cached_ids,
        :title,
        :card_overlay,
        :card_class,
        :count_entry
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
  deck, as established on the deck detail page: mana curve chart, a
  text card list section (with a Sideboard column), and an image
  section of main-deck stacks plus the sideboard as a splayed row.

  A `CompositionPrefs` struct (the global preference owned by
  `Scry2Web.DeckViewScope`) drives which sections render, their order,
  and each section's grouping. Each section header carries its own
  Type/Mana grouping toggle and — when both sections are visible — a
  swap control flipping which is on top.
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

  attr :prefs, CompositionPrefs,
    default: %CompositionPrefs{},
    doc: "The global composition preference — see `Scry2Web.DeckViewScope`."

  attr :count_entry, :any,
    default: nil,
    doc: "Forwarded to every image view — see `deck_view/1`."

  attr :main_label, :string,
    default: "main deck",
    doc: """
    Heading of the image section's main grid. Override when the cards
    aren't a literal deck — e.g. an archetype's shared core.
    """

  attr :unresolved, :list,
    default: [],
    doc: """
    Card references that never resolved to an arena_id (`%{name, count}`,
    from `Scry2Web.NetdecksHelpers.unresolved_entries/1`), rendered as
    placeholder tiles flagged "Not on MTGA" — distinct from the ownership
    wash, since these are never fixable by crafting.
    """

  slot :card_overlay, doc: "Forwarded to every image view — see `deck_view/1`."

  def standard_composition(assigns) do
    assigns =
      assign(assigns,
        main_total: card_count(assigns.main_deck),
        side_total: card_count(assigns.sideboard),
        section_order: CompositionPrefs.section_order(assigns.prefs),
        show_swap: assigns.prefs.display_mode == :both
      )

    ~H"""
    <div :if={not empty?(@main_deck, @sideboard)}>
      <div class="flex justify-end mb-2">
        <.deck_display_mode_toggle mode={@prefs.display_mode} />
      </div>

      <%!-- Mana Curve — half width, space reserved for future chart --%>
      <div :if={@show_curve} class="w-1/2">
        <.mana_curve_chart
          id={"#{@id}-curve"}
          cards={@main_deck}
          cards_by_arena_id={@cards_by_arena_id}
        />
      </div>

      <div class={["space-y-8", @show_curve && "mt-8"]}>
        <%= for section <- @section_order do %>
          <%= case section do %>
            <% :text -> %>
              <.text_section
                id={@id}
                prefs={@prefs}
                show_swap={@show_swap}
                main_deck={@main_deck}
                sideboard={@sideboard}
                side_total={@side_total}
                cards_by_arena_id={@cards_by_arena_id}
                cached_ids={@cached_ids}
                card_class={@card_class}
                unresolved={@unresolved}
              />
            <% :images -> %>
              <.images_section
                id={@id}
                prefs={@prefs}
                show_swap={@show_swap}
                main_deck={@main_deck}
                sideboard={@sideboard}
                main_label={@main_label}
                main_total={@main_total}
                side_total={@side_total}
                cards_by_arena_id={@cards_by_arena_id}
                cached_ids={@cached_ids}
                card_overlay={@card_overlay}
                count_entry={@count_entry}
                unresolved={@unresolved}
              />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # The text card list section: header with its grouping toggle, then
  # the text view (with a Sideboard column when the sideboard has cards).
  attr :id, :string, required: true
  attr :prefs, CompositionPrefs, required: true
  attr :show_swap, :boolean, required: true
  attr :main_deck, :any, required: true
  attr :sideboard, :any, required: true
  attr :side_total, :integer, required: true
  attr :cards_by_arena_id, :map, required: true
  attr :cached_ids, :any, required: true
  attr :card_class, :any, required: true
  attr :unresolved, :list, required: true

  defp text_section(assigns) do
    assigns =
      assign(assigns, :spec, %ViewSpec{group_by: assigns.prefs.text_group_by, display: :text})

    ~H"""
    <div>
      <div class="flex items-center justify-between mb-3">
        <.kind_label>card list</.kind_label>
        <.section_controls field="text_group_by" prefs={@prefs} show_swap={@show_swap} />
      </div>
      <.deck_view
        id={"#{@id}-list"}
        spec={@spec}
        cards={@main_deck}
        sections={if @side_total > 0, do: [{"Sideboard", @sideboard}], else: []}
        cards_by_arena_id={@cards_by_arena_id}
        cached_ids={@cached_ids}
        card_class={@card_class}
      />
      <.unresolved_text_list
        :if={@unresolved != []}
        id={"#{@id}-unresolved"}
        unresolved={@unresolved}
      />
    </div>
    """
  end

  # The image section: header with its grouping toggle, then the
  # main-deck stacks and the sideboard splay row inside one view group.
  attr :id, :string, required: true
  attr :prefs, CompositionPrefs, required: true
  attr :show_swap, :boolean, required: true
  attr :main_deck, :any, required: true
  attr :sideboard, :any, required: true
  attr :main_label, :string, required: true
  attr :main_total, :integer, required: true
  attr :side_total, :integer, required: true
  attr :cards_by_arena_id, :map, required: true
  attr :cached_ids, :any, required: true
  attr :card_overlay, :list, required: true
  attr :count_entry, :any, required: true
  attr :unresolved, :list, required: true

  defp images_section(assigns) do
    assigns =
      assign(assigns,
        grid_spec: %ViewSpec{
          group_by: assigns.prefs.images_group_by,
          display: :images,
          layout: :columns,
          count_placement: :gutter
        },
        row_spec: %ViewSpec{display: :images, layout: :row}
      )

    ~H"""
    <div>
      <div class="flex items-center justify-between">
        <.kind_label>{@main_label} ({@main_total})</.kind_label>
        <.section_controls field="images_group_by" prefs={@prefs} show_swap={@show_swap} />
      </div>

      <.deck_view_group id={"#{@id}-view"} class="mt-3">
        <.deck_view
          id={"#{@id}-grid"}
          spec={@grid_spec}
          cards={@main_deck}
          cards_by_arena_id={@cards_by_arena_id}
          cached_ids={@cached_ids}
          count_entry={@count_entry}
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
          count_entry={@count_entry}
          title={"sideboard (#{@side_total})"}
        >
          <:card_overlay :let={card} :if={@card_overlay != []}>
            {render_slot(@card_overlay, card)}
          </:card_overlay>
        </.deck_view>
      </.deck_view_group>

      <.unresolved_image_grid
        :if={@unresolved != []}
        id={"#{@id}-unresolved-grid"}
        unresolved={@unresolved}
      />
    </div>
    """
  end

  # Placeholder rows for card references that never resolved to an
  # arena_id — no art, no type/mana data, just the name and a flag that
  # this card doesn't exist on Arena at all. Never fixable by crafting,
  # unlike the ownership wash the ordinary rows carry.
  attr :id, :string, required: true
  attr :unresolved, :list, required: true

  defp unresolved_text_list(assigns) do
    ~H"""
    <div class="mt-4">
      <h3 class="flex items-center gap-2 text-xs font-medium text-base-content/40 uppercase tracking-wide mb-1">
        <span class="w-4 shrink-0" />Not on MTGA
      </h3>
      <div class="space-y-0.5">
        <div
          :for={{entry, index} <- Enum.with_index(@unresolved)}
          id={"#{@id}-#{index}"}
          class="flex items-baseline gap-2 text-sm py-0.5 text-base-content/40"
        >
          <span class="w-4 text-right tabular-nums shrink-0">{entry.count}</span>
          <span class="italic">{entry.name}</span>
          <span class="badge badge-xs badge-ghost">not on MTGA</span>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :unresolved, :list, required: true

  defp unresolved_image_grid(assigns) do
    ~H"""
    <div class="mt-4">
      <h3 class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-1">
        Not on MTGA
      </h3>
      <div class="flex gap-3 flex-wrap mt-2">
        <div
          :for={{entry, index} <- Enum.with_index(@unresolved)}
          id={"#{@id}-#{index}"}
          class="w-24 aspect-[488/680] rounded border border-dashed border-base-content/20 bg-base-200/40 flex flex-col items-center justify-center p-2 text-center"
        >
          <span class="text-xs text-base-content/50 leading-tight">{entry.name}</span>
          <span :if={entry.count > 1} class="text-[10px] text-base-content/35 tabular-nums mt-1">
            ×{entry.count}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # One section header's control cluster: the Type/Mana grouping toggle
  # for `field` (`"text_group_by"` or `"images_group_by"`) plus, when
  # both sections are visible, the swap button flipping section order.
  # All controls emit `set_deck_view_pref` with field + to, handled
  # by `Scry2Web.DeckViewScope`. Styled per UIDR-008 — soft, never a
  # solid fill.
  attr :field, :string, required: true
  attr :prefs, CompositionPrefs, required: true
  attr :show_swap, :boolean, required: true

  defp section_controls(assigns) do
    assigns =
      assign(assigns,
        group_by: Map.fetch!(assigns.prefs, String.to_existing_atom(assigns.field)),
        options: [{"type", "Type"}, {"mana_value", "Mana"}]
      )

    ~H"""
    <div class="flex items-center gap-1">
      <div class="join">
        <button
          :for={{value, label} <- @options}
          type="button"
          phx-click="set_deck_view_pref"
          phx-value-field={@field}
          phx-value-to={value}
          class={[
            "join-item btn btn-xs",
            if(Atom.to_string(@group_by) == value, do: "btn-active", else: "btn-ghost")
          ]}
        >
          {label}
        </button>
      </div>
      <button
        :if={@show_swap}
        type="button"
        title="Swap section order"
        phx-click="set_deck_view_pref"
        phx-value-field="top"
        phx-value-to={Atom.to_string(CompositionPrefs.flipped_top(@prefs))}
        class="btn btn-xs btn-ghost btn-square"
      >
        <.icon name="hero-arrows-up-down" class="size-3.5" />
      </button>
    </div>
    """
  end

  @doc """
  The 3-way segmented control selecting the composition's
  `display_mode` (Text / Images / Both). Each segment emits
  `set_deck_view_pref` with `field="display_mode"`; the `DeckViewScope`
  hook persists the choice and re-assigns the prefs. Styled per
  UIDR-008 — a soft `join` group, active segment subtle, never a solid
  fill.
  """
  attr :mode, :atom, required: true

  def deck_display_mode_toggle(assigns) do
    assigns =
      assign(assigns, :options, [{"text", "Text"}, {"images", "Images"}, {"both", "Both"}])

    ~H"""
    <div class="join">
      <button
        :for={{value, label} <- @options}
        type="button"
        phx-click="set_deck_view_pref"
        phx-value-field="display_mode"
        phx-value-to={value}
        class={[
          "join-item btn btn-xs",
          if(to_string(@mode) == value, do: "btn-active", else: "btn-ghost")
        ]}
      >
        {label}
      </button>
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
  attr :count_entry, :any, default: nil

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
              phx-hook="CardHover"
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
  attr :count_entry, :any, default: nil

  defp columns_view(assigns) do
    ~H"""
    <div>
      <.kind_label :if={@title}>{@title}</.kind_label>
      <div class="flex gap-3 items-start" data-deck-grid>
        <div
          :for={{{label, cards}, section_idx} <- Enum.with_index(@resolved_sections)}
          class="flex-1 min-w-0 max-w-48 flex flex-col items-center"
        >
          <p :if={label} class="text-xs text-base-content/30 mb-1">{label}</p>
          <div class="flex w-full">
            <div
              class="relative flex-1 min-w-0"
              data-card-stack
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
                {render_slot(@card_overlay, card)}
                <.count_badge
                  card={card}
                  presentation={@count_presentation}
                  position="top-1 right-1"
                  entry_fun={@count_entry}
                />
              </div>
            </div>
            <%!-- Count rail: numbers aligned with each card's title strip,
                  in space reserved beside the stack so nothing printed on
                  the card is ever covered (UIDR-015). Blank means one. --%>
            <div :if={@count_presentation == :gutter} class="relative w-5 shrink-0">
              <%= for {card, card_idx} <- Enum.with_index(cards), entry = rail_entry(@count_entry, card), entry != nil do %>
                <span
                  class={[
                    "absolute left-1.5 text-xs tabular-nums",
                    entry[:class] || "text-base-content/50"
                  ]}
                  style={"top: calc(#{stack_top_percent(card_idx, length(cards), @spec.splay_depth)}% + 2px); z-index: #{card_idx}"}
                  title={entry[:title]}
                >
                  {entry.label}
                </span>
              <% end %>
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
  attr :count_entry, :any, default: nil

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
          {render_slot(@card_overlay, card)}
          <.count_badge
            card={card}
            presentation={@count_presentation}
            position="bottom-1 left-1"
            entry_fun={@count_entry}
          />
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
  attr :count_entry, :any, default: nil

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
              {render_slot(@card_overlay, card)}
              <.count_badge
                card={card}
                presentation={@count_presentation}
                position="bottom-1 right-1"
                entry_fun={@count_entry}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Count presentation ──────────────────────────────────────────────

  @doc """
  How a view presents piled card counts (UIDR-015):

  - `:none` — spread piling (each copy is its own card), or an explicit
    `count_placement: :none` for callers whose `card_overlay` draws its
    own counts (e.g. the deck diff markers).
  - `:gutter` — a rail reserved beside each `:columns` stack, counts
    as dimmed numbers aligned with their card's title strip.
  - `:badge` — the overlay pill on the card image. Also the fallback
    for `count_placement: :gutter` outside `:columns`, whose cards
    overlap or float so no rail can be reserved.

  The `card_overlay` slot is additive annotation and does not participate.
  """
  @spec count_presentation(ViewSpec.t()) :: :none | :gutter | :badge
  def count_presentation(%ViewSpec{piling: :spread}), do: :none
  def count_presentation(%ViewSpec{count_placement: :none}), do: :none
  def count_presentation(%ViewSpec{count_placement: :gutter, layout: :columns}), do: :gutter
  def count_presentation(%ViewSpec{}), do: :badge

  @doc """
  A piled count as rendered in the gutter rail — `nil` for a single
  copy, so the rail only carries information (blank means one).
  """
  @spec rail_count_label(pos_integer()) :: String.t() | nil
  def rail_count_label(count) when is_integer(count) and count > 1, do: Integer.to_string(count)
  def rail_count_label(_count), do: nil

  # The card's count pill, rendered only for the `:badge` presentation
  # (`:gutter`'s rail is drawn by `columns_view`; `:none` draws nothing).
  # `entry` customizes label/tone/tooltip; nil hides the pill.
  attr :card, :map, required: true
  attr :presentation, :atom, required: true
  attr :position, :string, required: true
  attr :entry_fun, :any, required: true

  defp count_badge(%{presentation: :badge} = assigns) do
    assigns = assign(assigns, :entry, badge_entry(assigns.entry_fun, assigns.card))

    ~H"""
    <span
      :if={@entry}
      class={[
        "absolute min-w-5 text-center rounded bg-black/70 px-1 text-xs font-bold pointer-events-none",
        @entry[:class] || "text-white",
        @position
      ]}
      title={@entry[:title]}
    >
      {@entry.label}
    </span>
    """
  end

  defp count_badge(assigns) do
    ~H""
  end

  # Count entries: the default badge always shows the count; the default
  # rail shows `rail_count_label` (blank means one). A caller `count_entry`
  # function overrides both.
  defp badge_entry(nil, card), do: %{label: card.count, class: nil, title: nil}
  defp badge_entry(entry_fun, card), do: entry_fun.(card)

  defp rail_entry(nil, card) do
    case rail_count_label(card.count) do
      nil -> nil
      label -> %{label: label, class: nil, title: nil}
    end
  end

  defp rail_entry(entry_fun, card), do: entry_fun.(card)

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
end
