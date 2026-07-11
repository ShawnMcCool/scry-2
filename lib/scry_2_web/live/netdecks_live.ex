defmodule Scry2Web.NetdecksLive do
  @moduledoc """
  LiveView for the NetDecking corpus catalog.

  Groups all reference decks by buildability status — Buildable now / Craftable now /
  Within reach — so the player immediately sees what they can take to a match.
  The detail view (`/netdecks/:id`) breaks a deck down card-by-card with owned /
  missing markers, the wildcard cost to finish it, and an MTGA-ready import string.

  Per the Phoenix Iron Law, all data loading happens in `handle_params/3`, never
  `mount/3`. Re-scores live whenever a new collection snapshot arrives. All
  non-trivial logic lives in `Scry2Web.NetdecksHelpers` (ADR-013); this module is
  thin wiring.
  """
  use Scry2Web, :live_view

  alias Scry2.NetDecking
  alias Scry2.NetDecking.IngestSource
  alias Scry2Web.CardImages
  alias Scry2Web.NetdecksHelpers
  alias Scry2.Topics

  @empty_catalog %{buildable: [], craftable: [], short: []}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.collection_snapshots())

    browse_sources = NetdecksHelpers.browse_source_options(NetDecking.browsable_sources())

    {:ok,
     assign(socket,
       search: "",
       catalog: @empty_catalog,
       detail: nil,
       sources: [],
       cached_card_ids: CardImages.empty(),
       import_open: false,
       import_mode: "paste",
       browse_sources: browse_sources,
       browse: NetdecksHelpers.initial_browse(browse_sources),
       imported_urls: MapSet.new()
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case NetDecking.get_deck(id) do
      nil -> {:noreply, push_navigate(socket, to: ~p"/netdecks")}
      deck -> {:noreply, assign_detail(socket, NetDecking.deck_detail(deck))}
    end
  end

  def handle_params(_params, _uri, socket) do
    catalog = NetDecking.catalog()

    art_ids =
      [catalog.buildable, catalog.craftable, catalog.short]
      |> List.flatten()
      |> Enum.flat_map(& &1.signature_arena_ids)
      |> Enum.uniq()

    # Art crops for the tiles; full cards for the hover popup (CardHover
    # pops the full card, not the crop).
    socket =
      socket
      |> assign(
        detail: nil,
        catalog: catalog,
        sources: NetDecking.source_status(),
        imported_urls: NetDecking.imported_source_urls()
      )
      |> CardImages.request(art_ids, variants: [:art, :full])

    {:noreply, socket}
  end

  @impl true
  def handle_event("import", %{"import" => params}, socket) do
    case NetDecking.import_decklist(%{
           name: params["name"],
           archetype: presence(params["archetype"]),
           source_name: "manual",
           decklist_text: params["decklist_text"] || ""
         }) do
      {:ok, deck} ->
        {:noreply,
         socket
         |> put_flash(:info, "Imported “#{deck.name}”.")
         |> assign(catalog: NetDecking.catalog())}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not import that deck. Check the name and list.")}
    end
  end

  def handle_event("search", %{"value" => query}, socket) do
    {:noreply, assign(socket, search: query)}
  end

  def handle_event("toggle_import_panel", _params, socket) do
    {:noreply, assign(socket, import_open: not socket.assigns.import_open)}
  end

  def handle_event("import_mode", %{"mode" => mode}, socket) when mode in ~w(paste browse) do
    socket = assign(socket, import_mode: mode)

    if mode == "browse" and browse_needs_load?(socket.assigns.browse) do
      {:noreply, load_events(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("browse_config", params, socket) do
    browse = socket.assigns.browse

    chosen_option =
      Enum.find(socket.assigns.browse_sources, fn option -> option.name == params["source"] end)

    browse =
      cond do
        chosen_option && chosen_option.name != browse.source_name ->
          %{
            browse
            | source: chosen_option.module,
              source_name: chosen_option.name,
              formats: chosen_option.formats,
              format: List.first(chosen_option.formats)
          }

        params["format"] in browse.formats ->
          %{browse | format: params["format"]}

        true ->
          browse
      end

    {:noreply, socket |> assign(browse: browse) |> load_events()}
  end

  def handle_event("browse_load", _params, socket) do
    {:noreply, load_events(socket)}
  end

  def handle_event("browse_toggle_event", %{"url" => url}, socket) do
    browse = socket.assigns.browse
    selected = NetdecksHelpers.toggle_selection(browse.selected, url)
    {:noreply, assign(socket, browse: %{browse | selected: selected})}
  end

  def handle_event("browse_import", _params, socket) do
    browse = socket.assigns.browse
    event_urls = MapSet.to_list(browse.selected)
    source = browse.source

    if event_urls == [] or browse.importing? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(browse: %{browse | importing?: true})
       |> start_async(:browse_import, fn ->
         Enum.map(event_urls, fn event_url -> IngestSource.run_event(source, event_url) end)
       end)}
    end
  end

  def handle_event("toggle_auto_fetch", %{"source" => source_name}, socket) do
    enabled = not NetDecking.auto_fetch_enabled?(source_name)
    NetDecking.set_auto_fetch(source_name, enabled)

    browse = socket.assigns.browse
    {:noreply, assign(socket, browse: %{browse | auto_fetch?: enabled})}
  end

  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, "Copied — switch to MTGA → Import in the Deck Builder.")}
  end

  def handle_event("copy_failed", _params, socket) do
    {:noreply,
     put_flash(socket, :error, "Couldn't reach the clipboard. Select the text to copy manually.")}
  end

  @impl true
  def handle_async(:browse_events, {:ok, {:ok, events}}, socket) do
    browse = socket.assigns.browse
    {:noreply, assign(socket, browse: %{browse | events: events, loading?: false})}
  end

  def handle_async(:browse_events, {:ok, {:error, _reason}}, socket) do
    {:noreply, assign_browse_error(socket)}
  end

  def handle_async(:browse_events, {:exit, _reason}, socket) do
    {:noreply, assign_browse_error(socket)}
  end

  def handle_async(:browse_import, {:ok, results}, socket) do
    browse = socket.assigns.browse

    {:noreply,
     socket
     |> assign(
       browse: %{browse | importing?: false, selected: MapSet.new()},
       catalog: NetDecking.catalog(),
       sources: NetDecking.source_status(),
       imported_urls: NetDecking.imported_source_urls()
     )
     |> put_flash(:info, NetdecksHelpers.import_flash(results))}
  end

  def handle_async(:browse_import, {:exit, _reason}, socket) do
    browse = socket.assigns.browse

    {:noreply,
     socket
     |> assign(browse: %{browse | importing?: false})
     |> put_flash(:error, "Import crashed — nothing may have been saved. Try again.")}
  end

  @impl true
  def handle_info({:snapshot_saved, _snapshot}, socket) do
    socket =
      if detail = socket.assigns.detail do
        assign_detail(socket, NetDecking.deck_detail(detail.deck))
      else
        assign(socket, catalog: NetDecking.catalog())
      end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      catch_up_status={@catch_up_status}
      sidebar_collapsed={@sidebar_collapsed}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <.detail :if={@detail} detail={@detail} cached_ids={@cached_card_ids} />
      <.catalog
        :if={is_nil(@detail)}
        catalog={@catalog}
        search={@search}
        sources={@sources}
        cached_ids={@cached_card_ids}
        import_open={@import_open}
        import_mode={@import_mode}
        browse={@browse}
        browse_sources={@browse_sources}
        imported_urls={@imported_urls}
      />
    </Layouts.app>
    """
  end

  # ── Catalog view ─────────────────────────────────────────────────────────

  attr :catalog, :map, required: true
  attr :search, :string, required: true
  attr :sources, :list, required: true
  attr :cached_ids, :any, required: true
  attr :import_open, :boolean, required: true
  attr :import_mode, :string, required: true
  attr :browse, :map, required: true
  attr :browse_sources, :list, required: true
  attr :imported_urls, :any, required: true

  defp catalog(assigns) do
    assigns = assign(assigns, :total, catalog_total(assigns.catalog))

    ~H"""
    <div class="mb-6 mt-4">
      <.kind_label class="mb-1">netdecks</.kind_label>
      <h1 class="text-2xl font-beleren leading-tight">Standard Netdecks</h1>
      <p class="text-sm text-base-content/55 mt-1">
        Paste decks from anywhere — see what you can build now and what's a wildcard away.
      </p>
    </div>

    <div class="flex flex-wrap items-center gap-2 mb-6 text-xs text-base-content/55">
      <span :for={source <- @sources} class="badge badge-sm badge-ghost gap-1">
        {source.source_name} · {source.count}
      </span>
    </div>

    <div class="bg-base-200 rounded-xl mb-6">
      <button
        type="button"
        phx-click="toggle_import_panel"
        class="w-full text-left cursor-pointer select-none px-4 py-3 text-sm font-medium flex items-center gap-2"
      >
        <.icon name={if @import_open, do: "hero-chevron-down", else: "hero-plus"} class="size-4" />
        Import decks
      </button>

      <div :if={@import_open}>
        <div role="tablist" class="tabs tabs-border px-4">
          <button
            type="button"
            role="tab"
            class={["tab", @import_mode == "paste" && "tab-active"]}
            phx-click="import_mode"
            phx-value-mode="paste"
          >
            Paste
          </button>
          <button
            :if={@browse}
            type="button"
            role="tab"
            class={["tab", @import_mode == "browse" && "tab-active"]}
            phx-click="import_mode"
            phx-value-mode="browse"
          >
            Browse
          </button>
        </div>

        <form
          :if={@import_mode == "paste"}
          id="netdeck-import"
          phx-submit="import"
          class="px-4 py-4 space-y-3"
        >
          <div class="flex flex-col sm:flex-row gap-2">
            <input
              type="text"
              name="import[name]"
              required
              placeholder="Deck name"
              class="input input-bordered input-sm flex-1"
            />
            <input
              type="text"
              name="import[archetype]"
              placeholder="Archetype (optional)"
              class="input input-bordered input-sm flex-1"
            />
          </div>
          <textarea
            name="import[decklist_text]"
            placeholder="Deck&#10;4 Lightning Bolt (M21) 162&#10;…"
            rows="6"
            class="textarea textarea-bordered w-full text-sm font-mono"
          ></textarea>
          <div class="flex justify-end">
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-down-tray" class="size-4" /> Import
            </button>
          </div>
        </form>

        <.browse_pane
          :if={@import_mode == "browse" && @browse}
          browse={@browse}
          browse_sources={@browse_sources}
          imported_urls={@imported_urls}
        />
      </div>
    </div>

    <.empty_state :if={@total == 0} icon="hero-rectangle-stack">
      No decks yet — paste an MTGA decklist above to start your catalog.
    </.empty_state>

    <div :if={@total > 0} class="mb-5">
      <label class="input input-bordered input-sm flex items-center gap-2 w-full max-w-md">
        <.icon name="hero-magnifying-glass" class="size-4 text-base-content/40" />
        <input
          type="text"
          phx-keyup="search"
          phx-debounce="200"
          value={@search}
          placeholder="Search by name or archetype…"
          class="grow"
        />
      </label>
    </div>

    <section :for={status <- NetdecksHelpers.status_order()} :if={@total > 0} class="mb-8">
      <% meta = NetdecksHelpers.status_meta(status) %>
      <% entries = visible(@catalog[status], @search) %>
      <h2 class="flex items-center gap-2 text-xs font-semibold uppercase tracking-widest mb-2">
        <.icon name={meta.icon} class={["size-4", meta.tone]} />
        <span class="text-base-content/70">{meta.section}</span>
        <span class="badge badge-sm badge-ghost">{length(entries)}</span>
      </h2>

      <p :if={entries == []} class="text-sm text-base-content/30 italic pl-6 pb-2">
        Nothing here yet.
      </p>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
        <.deck_tile
          :for={entry <- entries}
          entry={entry}
          cached_ids={@cached_ids}
        />
      </div>
    </section>
    """
  end

  # ── Import browser (UIDR-011) ────────────────────────────────────────────

  attr :browse, :map, required: true
  attr :browse_sources, :list, required: true
  attr :imported_urls, :any, required: true

  defp browse_pane(assigns) do
    ~H"""
    <div class="px-4 py-4 space-y-3">
      <div class="flex flex-wrap items-center gap-3">
        <form phx-change="browse_config" class="flex flex-wrap items-center gap-2">
          <select name="source" class="select select-bordered select-sm w-auto">
            <option
              :for={option <- @browse_sources}
              value={option.name}
              selected={option.name == @browse.source_name}
            >
              {option.name}
            </option>
          </select>
          <select
            name="format"
            class="select select-bordered select-sm w-auto"
            disabled={length(@browse.formats) <= 1}
          >
            <option
              :for={format <- @browse.formats}
              value={format}
              selected={format == @browse.format}
            >
              {format}
            </option>
          </select>
        </form>

        <label class="flex items-center gap-2 text-xs text-base-content/55 cursor-pointer">
          <input
            type="checkbox"
            class="toggle toggle-xs"
            checked={@browse.auto_fetch?}
            phx-click="toggle_auto_fetch"
            phx-value-source={@browse.source_name}
          /> Fetch new events daily
        </label>
      </div>

      <div
        :if={@browse.loading?}
        class="flex items-center gap-2 text-sm text-base-content/55 py-2"
      >
        <span class="loading loading-spinner loading-sm"></span> Loading events…
      </div>

      <div
        :if={@browse.error}
        class="flex items-center gap-3 text-sm bg-warning/10 text-warning rounded-lg p-3"
      >
        <span class="flex-1">{@browse.error}</span>
        <button type="button" phx-click="browse_load" class="btn btn-xs btn-ghost">
          Retry
        </button>
      </div>

      <p
        :if={@browse.events == [] && !@browse.loading? && !@browse.error}
        class="text-sm text-base-content/55 py-2"
      >
        No events listed for {@browse.format} right now.
      </p>

      <div
        :if={@browse.events && @browse.events != []}
        class="rounded-lg border border-base-300/40 divide-y divide-base-300/40"
      >
        <label
          :for={event <- @browse.events}
          class="flex items-center gap-3 px-3 py-2 text-sm cursor-pointer hover:bg-base-300/20"
        >
          <input
            type="checkbox"
            class="checkbox checkbox-sm"
            phx-click="browse_toggle_event"
            phx-value-url={event.url}
            checked={MapSet.member?(@browse.selected, event.url)}
          />
          <span class="min-w-0 flex-1 truncate">{event.name}</span>
          <span :if={event.date} class="text-xs text-base-content/45 tabular-nums shrink-0">
            {NetdecksHelpers.format_event_date(event.date)}
          </span>
          <span
            :if={MapSet.member?(@imported_urls, event.url)}
            class="badge badge-xs badge-ghost shrink-0"
          >
            imported
          </span>
        </label>
      </div>

      <div :if={@browse.events && @browse.events != []} class="flex justify-end">
        <button
          type="button"
          phx-click="browse_import"
          disabled={MapSet.size(@browse.selected) == 0 || @browse.importing?}
          class="btn btn-primary btn-sm"
        >
          <span :if={@browse.importing?} class="loading loading-spinner loading-xs"></span>
          <.icon
            :if={!@browse.importing?}
            name="hero-arrow-down-tray"
            class="size-4"
          /> Import selected events
        </button>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :cached_ids, :any, required: true

  defp deck_tile(assigns) do
    [hero | micros] = pad_signature(assigns.entry.signature_arena_ids)

    assigns =
      assign(assigns,
        hero: hero,
        micros: micros,
        subtitle: NetdecksHelpers.tile_subtitle(assigns.entry.provenance)
      )

    ~H"""
    <.link
      patch={~p"/netdecks/#{@entry.deck.id}"}
      class="flex gap-3 p-3 rounded-xl bg-base-200/60 hover:bg-base-200 border border-base-300/40 transition-colors"
    >
      <div class="flex gap-1.5 shrink-0">
        <.card_image
          :if={@hero}
          arena_id={@hero}
          variant={:art}
          class="w-[6.75rem] h-[5rem] object-cover"
          cached_ids={@cached_ids}
        />
        <div class="flex flex-col gap-1 justify-between">
          <%= for id <- @micros do %>
            <.card_image
              :if={id}
              arena_id={id}
              variant={:art}
              class="w-[4.25rem] h-[1.4rem] object-cover"
              cached_ids={@cached_ids}
            />
          <% end %>
        </div>
      </div>

      <div class="flex flex-col gap-1.5 min-w-0">
        <div class="font-medium leading-tight truncate">{@entry.label}</div>
        <div :if={@subtitle} class="text-xs text-base-content/55 truncate">{@subtitle}</div>
        <div class="flex items-center gap-2 text-xs text-base-content/55">
          <.mana_pips colors={@entry.color_identity} />
          <.set_icon :if={@entry.set_code} code={@entry.set_code} />
          <span class="tabular-nums">×{@entry.variant_count}</span>
        </div>
        <div
          :if={
            NetdecksHelpers.any_cost?(@entry.result.maindeck.wildcard_cost) ||
              !NetdecksHelpers.fully_owned?(@entry.result) ||
              sideboard_count(@entry.deck) > 0
          }
          class="flex items-center gap-2 text-xs"
        >
          <.cost_pips
            :if={NetdecksHelpers.any_cost?(@entry.result.maindeck.wildcard_cost)}
            cost={@entry.result.maindeck.wildcard_cost}
          />
          <span
            :if={!NetdecksHelpers.fully_owned?(@entry.result)}
            class="text-base-content/45 tabular-nums"
          >
            {NetdecksHelpers.format_owned_pct(@entry.result.maindeck.owned_pct)}
          </span>
          <span :if={sideboard_count(@entry.deck) > 0} class="badge badge-xs badge-ghost">
            SB {sideboard_count(@entry.deck)}
          </span>
        </div>
      </div>
    </.link>
    """
  end

  defp pad_signature(ids), do: Enum.take(ids ++ [nil, nil, nil, nil], 4)

  defp sideboard_count(%{sideboard: %{"cards" => cards}}) when is_list(cards),
    do: Enum.reduce(cards, 0, fn c, acc -> acc + (c["count"] || 0) end)

  defp sideboard_count(_), do: 0

  # ── Detail view ──────────────────────────────────────────────────────────

  attr :detail, :map, required: true
  attr :cached_ids, :any, required: true

  defp detail(assigns) do
    assigns =
      assign(assigns,
        meta: NetdecksHelpers.status_meta(assigns.detail.result.status),
        unresolved: NetdecksHelpers.unresolved_count(assigns.detail.deck),
        provenance_line: NetdecksHelpers.detail_provenance(assigns.detail),
        rows_by_arena_id:
          NetdecksHelpers.rows_by_arena_id(assigns.detail.main_rows, assigns.detail.side_rows)
      )

    ~H"""
    <div class="mt-4 mb-6">
      <.link
        patch={~p"/netdecks"}
        class="text-xs text-base-content/55 inline-flex items-center gap-1 mb-2"
      >
        <.icon name="hero-arrow-long-left" class="size-3" /> all netdecks
      </.link>
      <.kind_label class="mb-1">netdeck</.kind_label>
      <div class="flex items-center gap-3 flex-wrap">
        <h1 class="text-2xl font-beleren leading-tight">{@detail.label}</h1>
        <span class={["badge badge-sm", @meta.badge]}>{@meta.label}</span>
      </div>
      <div
        :if={@provenance_line || @detail.deck.source_url}
        class="flex items-center gap-2 mt-1 text-sm text-base-content/55 flex-wrap"
      >
        <span :if={@provenance_line}>{@provenance_line}</span>
        <a
          :if={@detail.deck.source_url}
          href={@detail.deck.source_url}
          target="_blank"
          rel="noopener"
          class="link link-hover inline-flex items-center gap-1"
        >
          {NetdecksHelpers.source_host(@detail.deck.source_url)}
          <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
        </a>
      </div>
      <div class="flex items-center gap-3 mt-2 text-xs text-base-content/55">
        <span :if={@detail.deck.archetype} class="badge badge-sm badge-ghost">
          {@detail.deck.archetype}
        </span>
        <span>via {@detail.deck.source_name}</span>
        <span :if={@detail.deck.fetched_at}>
          · {NetdecksHelpers.relative_time(@detail.deck.fetched_at)}
        </span>
      </div>
    </div>

    <div class="grid lg:grid-cols-[20rem_1fr] gap-6">
      <%!-- Craft summary --%>
      <div class="bg-base-200 rounded-xl p-5 space-y-4 self-start">
        <div>
          <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-widest mb-2">
            To craft
          </h3>
          <div
            :if={NetdecksHelpers.any_cost?(@detail.result.maindeck.wildcard_cost)}
            class="flex items-center gap-3"
          >
            <.cost_pips cost={@detail.result.maindeck.wildcard_cost} size="size-5" />
          </div>
          <p
            :if={!NetdecksHelpers.any_cost?(@detail.result.maindeck.wildcard_cost)}
            class="text-sm text-success"
          >
            You own every card.
          </p>
          <p
            :if={@detail.result.status == :short}
            class="text-xs text-warning mt-2 flex items-center gap-2"
          >
            Still need <.cost_pips cost={@detail.result.maindeck.shortfall} /> beyond your wildcards.
          </p>
          <p :if={@detail.result.status == :craftable} class="text-xs text-info mt-2">
            You have the wildcards to craft this now.
          </p>
        </div>

        <div :if={NetdecksHelpers.any_cost?(@detail.result.sideboard.wildcard_cost)}>
          <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-widest mb-2">
            Sideboard
          </h3>
          <.cost_pips cost={@detail.result.sideboard.wildcard_cost} />
        </div>

        <div>
          <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-widest mb-2">
            Your wildcards
          </h3>
          <div class="flex items-center gap-3">
            <span
              :for={rarity <- ~w(common uncommon rare mythic)}
              class="inline-flex items-center gap-1 text-sm text-base-content/70"
            >
              <.wildcard_icon rarity={rarity} class="size-4" />
              <span class="tabular-nums">
                {Map.get(@detail.wildcards, String.to_existing_atom(rarity))}
              </span>
            </span>
          </div>
        </div>

        <button
          type="button"
          class="btn btn-primary btn-sm w-full"
          phx-hook="ClipboardCopy"
          id="copy-to-mtga-button"
          data-copy-text={@detail.export_text}
          title="Copy this deck in MTGA's import format, then click Import in the Deck Builder."
        >
          <.icon name="hero-clipboard-document" class="size-4" /> Copy to MTGA
        </button>
      </div>

      <%!-- Decklist. min-w-0 keeps the 1fr track from growing to the splay's
           intrinsic width — without it the DeckView hook and the track feed
           each other and the layout blows out. --%>
      <div class="space-y-6 min-w-0">
        <div
          :if={@unresolved > 0}
          class="flex items-start gap-2 text-sm bg-warning/10 text-warning rounded-lg p-3"
        >
          <.icon name="hero-exclamation-triangle" class="size-4 mt-0.5 shrink-0" />
          <span>
            {@unresolved} card(s) in this list weren't recognised and aren't scored. They're often
            cards not in your local MTGA database yet.
          </span>
        </div>

        <.standard_composition
          id="netdeck"
          main_deck={@detail.deck.main_deck}
          sideboard={@detail.deck.sideboard}
          cards_by_arena_id={@detail.cards_by_arena_id}
          cached_ids={@cached_ids}
        >
          <:card_overlay :let={card}>
            <.ownership_marker row={Map.get(@rows_by_arena_id, card.arena_id)} count={card.count} />
          </:card_overlay>
        </.standard_composition>

        <.variants_list
          :if={length(@detail.variants) > 1}
          variants={@detail.variants}
          current_deck_id={@detail.deck.id}
        />
      </div>
    </div>
    """
  end

  # Every deck in the same cluster, best finish first (UIDR-010). Rows
  # navigate to that variant's detail; the row being viewed is marked.
  attr :variants, :list, required: true
  attr :current_deck_id, :integer, required: true

  defp variants_list(assigns) do
    ~H"""
    <div>
      <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-widest mb-2">
        Variants ({length(@variants)})
      </h3>
      <div class="rounded-xl bg-base-200/60 border border-base-300/40 divide-y divide-base-300/40">
        <.link
          :for={variant <- @variants}
          patch={~p"/netdecks/#{variant.deck.id}"}
          class={[
            "flex items-center gap-3 px-3 py-2 text-sm hover:bg-base-200 transition-colors",
            variant.deck.id == @current_deck_id && "bg-base-200/80"
          ]}
        >
          <span class="min-w-0 flex-1 truncate">
            {variant.deck.pilot || variant.deck.name}
          </span>
          <span :if={variant.finish} class="text-xs text-base-content/55 tabular-nums shrink-0">
            {variant.finish}
          </span>
          <span :if={variant.record} class="text-xs text-base-content/45 tabular-nums shrink-0">
            {variant.record}
          </span>
          <span
            :if={variant.deck.event_date}
            class="text-xs text-base-content/45 tabular-nums shrink-0 hidden sm:inline"
          >
            {NetdecksHelpers.format_event_date(variant.deck.event_date)}
          </span>
          <span class="shrink-0">
            <.cost_pips cost={variant.wildcard_cost} size="size-3.5" />
          </span>
          <span
            :if={variant.deck.id == @current_deck_id}
            class="badge badge-xs badge-ghost shrink-0"
          >
            viewing
          </span>
        </.link>
      </div>
    </div>
    """
  end

  # Ownership annotation rendered over every card in the standard deck
  # composition: unowned copies dim the card and the count badge takes the
  # ownership tone (owned / partial / missing / basic land).
  attr :row, :map, default: nil
  attr :count, :integer, required: true

  defp ownership_marker(assigns) do
    ~H"""
    <div
      :if={@row && @row.missing > 0}
      class="absolute inset-0 rounded-sm bg-base-100/60 pointer-events-none"
    />
    <span
      class={[
        "absolute top-1 right-1 min-w-5 text-center rounded bg-black/75 px-1 text-xs font-bold tabular-nums",
        NetdecksHelpers.card_row_tone(NetdecksHelpers.card_row_state(@row))
      ]}
      title={NetdecksHelpers.ownership_title(@row)}
    >
      <%= if @row && @row.free? do %>
        basic
      <% else %>
        {@count}
      <% end %>
    </span>
    """
  end

  # ── Shared pip component ─────────────────────────────────────────────────

  attr :cost, :map, required: true
  attr :size, :string, default: "size-4"

  defp cost_pips(assigns) do
    assigns = assign(assigns, :pips, NetdecksHelpers.cost_pips(assigns.cost))

    ~H"""
    <span class="inline-flex items-center gap-2">
      <span :if={@pips == []} class="text-xs text-base-content/40">—</span>
      <span
        :for={{rarity, count} <- @pips}
        class="inline-flex items-center gap-0.5 text-xs text-base-content/70"
      >
        <span class="tabular-nums">{count}</span>
        <.wildcard_icon rarity={to_string(rarity)} class={@size} />
      </span>
    </span>
    """
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  defp visible(entries, search) do
    Enum.filter(entries || [], &NetdecksHelpers.match_search?(&1, search))
  end

  defp browse_needs_load?(nil), do: false
  defp browse_needs_load?(browse), do: is_nil(browse.events) and not browse.loading?

  # Kicks off the async event listing for the current source + format.
  # HTTP stays out of the LiveView process; the pane shows a loading state.
  defp load_events(socket) do
    browse = socket.assigns.browse
    source = browse.source
    format = browse.format

    browse = %{
      browse
      | loading?: true,
        error: nil,
        events: nil,
        selected: MapSet.new(),
        auto_fetch?: NetDecking.auto_fetch_enabled?(browse.source_name)
    }

    socket
    |> assign(browse: browse)
    |> start_async(:browse_events, fn -> source.list_events(format) end)
  end

  defp assign_browse_error(socket) do
    browse = socket.assigns.browse

    error = "Couldn't load events from #{browse.source_name}. Check your connection."
    assign(socket, browse: %{browse | loading?: false, error: error})
  end

  # Loads a deck detail and precomputes the on-disk image set once (web concern,
  # not domain), mirroring DecksLive. Kept out of mount per the Phoenix Iron Law.
  defp assign_detail(socket, detail) do
    arena_ids =
      (detail.main_rows ++ detail.side_rows)
      |> Enum.map(& &1.arena_id)
      |> Enum.uniq()

    socket
    |> assign(detail: detail)
    |> CardImages.request(arena_ids)
  end

  defp catalog_total(catalog) do
    Enum.sum(Enum.map([:buildable, :craftable, :short], &length(catalog[&1] || [])))
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: String.trim(value) |> presence_trimmed()

  defp presence_trimmed(""), do: nil
  defp presence_trimmed(value), do: value
end
