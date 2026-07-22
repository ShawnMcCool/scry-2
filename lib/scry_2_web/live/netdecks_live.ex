defmodule Scry2Web.NetdecksLive do
  @moduledoc """
  LiveView for the NetDecking tiered archetype catalog (UIDR-017).

  Three screens:
  - `/netdecks` — archetype groups in three tiers (Buildable now / Craftable
    now / Within reach), ranked rows with finish medallions and the player's
    wildcard balance readout.
  - `/netdecks/archetype/:slug` — one archetype's variants, grouped
    buildable → craftable → short under a masthead with the best finish.
  - `/netdecks/:id` — one list card-by-card: owned/missing markers, wildcard
    cost, variant matrix, and an MTGA-ready import string.

  Per the Phoenix Iron Law, all data loading happens in `handle_params/3`, never
  `mount/3`. Re-scores live whenever a new collection snapshot arrives. All
  non-trivial logic lives in `Scry2Web.NetdecksHelpers` (ADR-013); this module is
  thin wiring.
  """
  use Scry2Web, :live_view

  alias Scry2.NetDecking
  alias Scry2.NetDecking.IngestSource
  alias Scry2.Topics
  alias Scry2Web.CardImages
  alias Scry2Web.DeckRendering
  alias Scry2Web.NetdecksHelpers

  import Scry2Web.Components.VariantMatrix, only: [variant_matrix: 1]

  @empty_catalog %{
    buildable: [],
    craftable: [],
    short: [],
    wildcards: %{common: 0, uncommon: 0, rare: 0, mythic: 0}
  }

  @per_page 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.collection_snapshots())

    browse_sources = NetdecksHelpers.browse_source_options(NetDecking.browsable_sources())

    {:ok,
     assign(socket,
       search: "",
       catalog: @empty_catalog,
       view: "status",
       page: 1,
       recent: nil,
       detail: nil,
       archetype: nil,
       archetype_extras: nil,
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
  def handle_params(%{"slug" => slug}, _uri, socket) do
    catalog = NetDecking.catalog()

    case NetdecksHelpers.find_group(catalog, slug) do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/netdecks")}

      group ->
        {:noreply, socket |> assign(detail: nil, catalog: catalog) |> assign_archetype(group)}
    end
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    case NetDecking.get_deck(id) do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/netdecks")}

      deck ->
        {:noreply,
         socket |> assign(archetype: nil) |> assign_detail(NetDecking.deck_detail(deck))}
    end
  end

  def handle_params(params, _uri, socket) do
    catalog = NetDecking.catalog()
    view = view_from_params(params)
    page = parse_page(params["page"])

    socket =
      socket
      |> assign(
        detail: nil,
        archetype: nil,
        catalog: catalog,
        view: view,
        page: page,
        sources: NetDecking.source_status(),
        imported_urls: NetDecking.imported_source_urls()
      )
      |> assign_view_content(view, page, catalog)

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
      cond do
        detail = socket.assigns.detail ->
          assign_detail(socket, NetDecking.deck_detail(detail.deck))

        group = socket.assigns.archetype ->
          # Re-score in place; the group may have shifted tier or vanished.
          catalog = NetDecking.catalog()
          socket = assign(socket, catalog: catalog)

          case NetdecksHelpers.find_group(catalog, group.slug) do
            nil -> assign(socket, archetype: nil, archetype_extras: nil)
            refreshed_group -> assign_archetype(socket, refreshed_group)
          end

        true ->
          socket = assign(socket, catalog: NetDecking.catalog())

          if socket.assigns.view == "recent" do
            # Refreshes cost/status data only — row order comes from the
            # `fetched_at` DB query, never from score, so it can't shift here.
            # TODO(Task 7): read the browsed format from assigns, not this literal.
            assign(socket,
              recent: NetDecking.recent_decks("Standard", socket.assigns.page, @per_page)
            )
          else
            socket
          end
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
      <.detail
        :if={@detail}
        detail={@detail}
        cached_ids={@cached_card_ids}
        prefs={@deck_view_prefs}
      />
      <.archetype_detail
        :if={@archetype && is_nil(@detail)}
        group={@archetype}
        extras={@archetype_extras}
        cached_ids={@cached_card_ids}
        prefs={@deck_view_prefs}
      />
      <.catalog
        :if={is_nil(@detail) && is_nil(@archetype)}
        catalog={@catalog}
        search={@search}
        sources={@sources}
        cached_ids={@cached_card_ids}
        import_open={@import_open}
        import_mode={@import_mode}
        browse={@browse}
        browse_sources={@browse_sources}
        imported_urls={@imported_urls}
        view={@view}
        recent={@recent}
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
  attr :view, :string, required: true
  attr :recent, :map, default: nil

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
      <%= for source <- @sources do %>
        <a
          :if={NetdecksHelpers.source_site_url(source.source_name)}
          href={NetdecksHelpers.source_site_url(source.source_name)}
          target="_blank"
          rel="noopener"
          class="badge badge-sm badge-ghost gap-1 link-hover"
          title={"Browse #{source.source_name} decklists"}
        >
          {source.source_name} · {source.count}
          <.icon name="hero-arrow-top-right-on-square" class="size-3 opacity-60" />
        </a>
        <span
          :if={is_nil(NetdecksHelpers.source_site_url(source.source_name))}
          class="badge badge-sm badge-ghost gap-1"
        >
          {source.source_name} · {source.count}
        </span>
      <% end %>
      <.wildcard_balance :if={@total > 0} wildcards={@catalog.wildcards} class="ml-auto" />
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

    <div :if={@total > 0} role="tablist" class="tabs tabs-border mb-6">
      <.link patch={~p"/netdecks"} role="tab" class={["tab", @view == "status" && "tab-active"]}>
        By status
      </.link>
      <.link
        patch={netdecks_path("recent", 1)}
        role="tab"
        class={["tab", @view == "recent" && "tab-active"]}
      >
        Recent
      </.link>
    </div>

    <div :if={@total > 0 && @view == "status"} class="mb-5">
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

    <section
      :for={status <- NetdecksHelpers.status_order()}
      :if={@total > 0 && @view == "status"}
      class="mb-10"
    >
      <% meta = NetdecksHelpers.status_meta(status) %>
      <% groups = visible(@catalog[status], @search) %>
      <div class="flex items-baseline gap-3 border-b border-base-300/40 pb-2">
        <.icon name={meta.icon} class={["size-4 self-center", meta.tone]} />
        <h2 class="text-lg font-beleren text-base-content/90">{meta.section}</h2>
        <span class="text-xs italic text-base-content/40 truncate">
          {meta.definition} — {meta.ordering}
        </span>
        <span class="ml-auto text-xs text-base-content/40 tabular-nums whitespace-nowrap">
          {length(groups)} archetypes
        </span>
      </div>

      <p :if={groups == []} class="text-sm text-base-content/30 italic pt-3 pl-7">
        Nothing here yet.
      </p>

      <ol class="divide-y divide-base-300/25">
        <li :for={{group, index} <- Enum.with_index(groups, 1)}>
          <.archetype_row group={group} rank={index} cached_ids={@cached_ids} />
        </li>
      </ol>
    </section>

    <.recent_list :if={@total > 0 && @view == "recent"} recent={@recent} cached_ids={@cached_ids} />
    """
  end

  # ── Recent view (UIDR-018) ───────────────────────────────────────────────

  attr :recent, :map, required: true
  attr :cached_ids, :any, required: true

  defp recent_list(assigns) do
    ~H"""
    <div>
      <p :if={@recent.entries == []} class="text-sm text-base-content/30 italic pt-3">
        Nothing recent yet.
      </p>

      <ol class="divide-y divide-base-300/25">
        <li :for={entry <- @recent.entries}>
          <.recent_deck_row entry={entry} cached_ids={@cached_ids} />
        </li>
      </ol>

      <.pagination
        :if={@recent.total_pages > 1}
        page={@recent.page}
        total_pages={@recent.total_pages}
      />
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :cached_ids, :any, required: true

  defp recent_deck_row(assigns) do
    entry = assigns.entry

    assigns =
      assign(assigns,
        hero: List.first(entry.signature_arena_ids),
        meta: NetdecksHelpers.status_meta(entry.result.status)
      )

    ~H"""
    <.link
      patch={~p"/netdecks/#{@entry.deck.id}"}
      class="grid grid-cols-[3.5rem_1fr] sm:grid-cols-[3.5rem_1fr_auto] items-center gap-4 py-4 px-1 hover:bg-base-200/40 transition-colors"
    >
      <.card_image
        :if={@hero}
        id={"recent-hero-#{@entry.deck.id}"}
        arena_id={@hero}
        variant={:art}
        class="w-14 h-[4.5rem] object-cover rounded border border-base-300/40"
        cached_ids={@cached_ids}
      />
      <span :if={is_nil(@hero)} class="w-14 h-[4.5rem] rounded bg-base-200/60"></span>

      <div class="min-w-0">
        <div class="flex items-baseline gap-3">
          <span class="font-beleren text-xl leading-tight truncate">{@entry.label}</span>
          <.mana_pips colors={@entry.color_identity} />
          <span class={["badge badge-sm", @meta.badge]}>{@meta.label}</span>
        </div>
        <div class="flex items-center gap-2 mt-1.5 text-sm text-base-content/55 min-w-0 flex-wrap">
          <span class="truncate">{@entry.deck.pilot || @entry.deck.name}</span>
          <span :if={@entry.finish} class="italic text-base-content/50 shrink-0">
            {@entry.finish}
          </span>
          <span :if={@entry.deck.event_name} class="text-base-content/40 truncate">
            · {@entry.deck.event_name}
            <span :if={@entry.deck.event_date}>
              · {NetdecksHelpers.format_event_date(@entry.deck.event_date)}
            </span>
          </span>
        </div>
        <div class="text-xs text-base-content/40 mt-1">
          via {@entry.deck.source_name} · {NetdecksHelpers.relative_time(@entry.deck.fetched_at)}
        </div>
      </div>

      <div class="col-start-2 sm:col-start-3 flex sm:flex-col items-center sm:items-end gap-2 sm:gap-1.5 sm:text-right">
        <span
          :if={!NetdecksHelpers.any_cost?(@entry.result.maindeck.wildcard_cost)}
          class="text-[10px] uppercase tracking-widest text-success/80"
        >
          owned — 0 wildcards
        </span>
        <.cost_pips
          :if={NetdecksHelpers.any_cost?(@entry.result.maindeck.wildcard_cost)}
          cost={@entry.result.maindeck.wildcard_cost}
          size="size-3.5"
        />
      </div>
    </.link>
    """
  end

  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true

  defp pagination(assigns) do
    assigns =
      assign(assigns, :window, NetdecksHelpers.page_window(assigns.page, assigns.total_pages))

    ~H"""
    <div class="flex items-center justify-center gap-1 mt-6">
      <.link
        :if={@page > 1}
        patch={netdecks_path("recent", @page - 1)}
        class="btn btn-xs btn-ghost"
        aria-label="Previous page"
      >
        <.icon name="hero-chevron-left" class="size-3.5" />
      </.link>

      <span :for={item <- @window}>
        <span :if={item == :ellipsis} class="px-1.5 text-base-content/30 select-none">…</span>
        <.link
          :if={item != :ellipsis}
          patch={netdecks_path("recent", item)}
          class={["btn btn-xs", if(item == @page, do: "btn-active", else: "btn-ghost")]}
        >
          {item}
        </.link>
      </span>

      <.link
        :if={@page < @total_pages}
        patch={netdecks_path("recent", @page + 1)}
        class="btn btn-xs btn-ghost"
        aria-label="Next page"
      >
        <.icon name="hero-chevron-right" class="size-3.5" />
      </.link>
    </div>
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

  # ── Archetype row (index tier entry, UIDR-017) ───────────────────────────

  attr :group, :map, required: true
  attr :rank, :integer, required: true
  attr :cached_ids, :any, required: true

  defp archetype_row(assigns) do
    group = assigns.group

    # A single-build archetype has no comparison to show, so link straight to
    # that build's page instead of the (redundant) archetype screen.
    href =
      case NetdecksHelpers.sole_variant_deck_id(group) do
        nil -> ~p"/netdecks/archetype/#{group.slug}"
        deck_id -> ~p"/netdecks/#{deck_id}"
      end

    assigns =
      assign(assigns,
        hero: List.first(group.signature_arena_ids),
        cheapest: NetdecksHelpers.cheapest_variant(group),
        href: href
      )

    ~H"""
    <.link
      patch={@href}
      class="grid grid-cols-[2.25rem_3.5rem_1fr] sm:grid-cols-[2.25rem_3.5rem_1fr_auto] items-center gap-4 py-4 px-1 hover:bg-base-200/40 transition-colors"
    >
      <span class="font-beleren text-2xl text-base-content/20 tabular-nums text-right">
        {@rank}
      </span>

      <.card_image
        :if={@hero}
        id={"archetype-hero-#{@group.slug}"}
        arena_id={@hero}
        variant={:art}
        class="w-14 h-[4.5rem] object-cover rounded border border-base-300/40"
        cached_ids={@cached_ids}
      />
      <span :if={is_nil(@hero)} class="w-14 h-[4.5rem] rounded bg-base-200/60"></span>

      <div class="min-w-0">
        <div class="flex items-baseline gap-3">
          <span class="font-beleren text-xl leading-tight truncate">{@group.label}</span>
          <.mana_pips colors={@group.color_identity} />
          <span
            :if={is_nil(@group.archetype_name)}
            class="badge badge-xs badge-ghost text-base-content/45"
            title="No community archetype matches this list — named after its colors and most distinctive card."
          >
            unclassified
          </span>
        </div>
        <div class="flex items-center gap-2.5 mt-1.5 text-sm text-base-content/55 min-w-0">
          <.medal finish={@group.provenance && @group.provenance.finish} />
          <span :if={@group.provenance} class="italic truncate">
            {NetdecksHelpers.tile_subtitle(@group.provenance)}
          </span>
          <span :if={is_nil(@group.provenance)} class="italic text-base-content/35">
            no recorded finishes
          </span>
        </div>
      </div>

      <div class="col-start-3 sm:col-start-4 flex sm:flex-col items-center sm:items-end gap-2 sm:gap-1.5 sm:text-right">
        <.tally_line tally={@group.tally} />
        <span
          :if={!NetdecksHelpers.any_cost?(@cheapest.result.maindeck.wildcard_cost)}
          class="text-[10px] uppercase tracking-widest text-success/80"
        >
          owned — 0 wildcards
        </span>
        <.cost_pips
          :if={NetdecksHelpers.any_cost?(@cheapest.result.maindeck.wildcard_cost)}
          cost={@cheapest.result.maindeck.wildcard_cost}
          size="size-3.5"
        />
      </div>
    </.link>
    """
  end

  attr :tally, :map, required: true

  defp tally_line(assigns) do
    assigns = assign(assigns, :parts, NetdecksHelpers.tally_parts(assigns.tally))

    ~H"""
    <span class="text-xs text-base-content/45 whitespace-nowrap">
      <%= for {{status, count}, index} <- Enum.with_index(@parts) do %>
        <span :if={index > 0} class="px-0.5">·</span>
        <span class={["tabular-nums", NetdecksHelpers.status_meta(status).tone]}>{count}</span>
        <span>{String.downcase(NetdecksHelpers.status_meta(status).label)}</span>
      <% end %>
    </span>
    """
  end

  attr :finish, :string, default: nil

  defp medal(assigns) do
    assigns = assign(assigns, :tone, NetdecksHelpers.medal_tone(assigns.finish))

    ~H"""
    <span
      :if={@finish}
      class={[
        "inline-flex items-center justify-center shrink-0 min-w-7 h-7 px-1 rounded-full border text-[11px] font-beleren",
        @tone == :gold && "border-warning/60 text-warning shadow-[0_0_0_3px] shadow-warning/10",
        @tone == :silver && "border-base-content/40 text-base-content/75",
        @tone == :neutral && "border-base-300/60 text-base-content/50"
      ]}
      title={@finish}
    >
      {NetdecksHelpers.medal_text(@finish)}
    </span>
    """
  end

  attr :wildcards, :map, required: true
  attr :class, :string, default: nil

  defp wildcard_balance(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-3", @class]} title="Your current wildcard pool">
      <span class="text-[10px] uppercase tracking-widest text-base-content/40">wildcards</span>
      <span
        :for={{rarity, count} <- NetdecksHelpers.wildcard_balances(@wildcards)}
        class="inline-flex items-center gap-1 text-xs text-base-content/70"
      >
        <.wildcard_icon rarity={to_string(rarity)} class="size-3.5" />
        <span class="tabular-nums">{count}</span>
      </span>
    </span>
    """
  end

  # ── Archetype detail (variants screen, UIDR-017) ─────────────────────────

  attr :group, :map, required: true
  attr :extras, :map, default: nil
  attr :cached_ids, :any, required: true
  attr :prefs, DeckRendering.CompositionPrefs, required: true

  defp archetype_detail(assigns) do
    ~H"""
    <div class="mt-4 mb-6">
      <.link
        patch={~p"/netdecks"}
        class="text-xs text-base-content/55 inline-flex items-center gap-1 mb-2"
      >
        <.icon name="hero-arrow-long-left" class="size-3" /> all netdecks
      </.link>
      <.kind_label class="mb-1">archetype</.kind_label>
      <div class="flex flex-wrap items-end justify-between gap-4 border-b border-base-300/40 pb-4">
        <div>
          <div class="flex items-baseline gap-3">
            <h1 class="text-2xl font-beleren leading-tight">{@group.label}</h1>
            <.mana_pips colors={@group.color_identity} />
            <span
              :if={is_nil(@group.archetype_name)}
              class="badge badge-sm badge-ghost text-base-content/45"
              title="No community archetype matches this list — named after its colors and most distinctive card."
            >
              unclassified
            </span>
          </div>
          <div class="mt-2 text-sm text-base-content/55">
            <span class="tabular-nums">{@group.list_count}</span>
            {if @group.list_count == 1, do: "list", else: "lists"}
            <span class="px-1">—</span>
            <.tally_line tally={@group.tally} />
          </div>
        </div>
        <div :if={@group.provenance} class="flex items-center gap-3">
          <.medal finish={@group.provenance.finish} />
          <div>
            <div class="text-[10px] uppercase tracking-widest text-base-content/40">
              best finish
            </div>
            <div class="text-sm italic text-base-content/55">
              {NetdecksHelpers.tile_subtitle(@group.provenance)}
            </div>
          </div>
        </div>
      </div>
    </div>

    <%!-- The archetype's typical list: cards in most member lists at their
          modal copy count, with the player's ownership overlaid — the
          summary doubles as a craft checklist (UIDR-017). Not a full
          deck — just the shared core, rendered through the standard
          composition so the global display/grouping controls apply. --%>
    <div :if={@extras && @extras.core != []} class="mb-10">
      <.kind_label class="mb-3">core — in most lists</.kind_label>
      <.standard_composition
        id="archetype-core"
        main_deck={@extras.core}
        cards_by_arena_id={@extras.cards_by_arena_id}
        cached_ids={@cached_ids}
        show_curve={false}
        prefs={@prefs}
        main_label="core"
        card_class={missing_card_tint(@extras.core_rows_by_arena_id)}
        count_entry={NetdecksHelpers.ownership_count_entry(@extras.core_rows_by_arena_id)}
      >
        <:card_overlay :let={card}>
          <.ownership_wash row={Map.get(@extras.core_rows_by_arena_id, card.arena_id)} />
        </:card_overlay>
      </.standard_composition>
    </div>

    <section :for={status <- NetdecksHelpers.status_order()} class="mb-2">
      <% meta = NetdecksHelpers.status_meta(status) %>
      <% variants = Enum.filter(@group.variants, &(&1.result.status == status)) %>
      <div :if={variants != []} class="pt-5 pb-1 flex items-baseline gap-2">
        <span class={["inline-block size-1.5 rounded-full self-center", meta.tone_dot]}></span>
        <span class="text-sm italic text-base-content/45">
          {meta.label} — {meta.definition}
        </span>
      </div>
      <div :if={variants != []} class="divide-y divide-base-300/25">
        <.variant_row
          :for={variant <- variants}
          variant={variant}
          meta={meta}
          delta_sections={variant_delta_sections(@extras, variant)}
          cached_ids={@cached_ids}
        />
      </div>
    </section>
    """
  end

  # The chip strip's data for one variant: its core deltas grouped by broad
  # type; empty when the extras haven't loaded or the variant matches the core.
  defp variant_delta_sections(nil, _variant), do: []

  defp variant_delta_sections(extras, variant) do
    NetdecksHelpers.delta_sections(
      Map.get(extras.deltas_by_deck_id, variant.deck.id, []),
      extras.cards_by_arena_id,
      Map.get(extras.craft_by_deck_id, variant.deck.id, %{})
    )
  end

  attr :variant, :map, required: true
  attr :meta, :map, required: true
  attr :delta_sections, :list, default: []
  attr :cached_ids, :any, required: true

  defp variant_row(assigns) do
    ~H"""
    <.link
      patch={~p"/netdecks/#{@variant.deck.id}"}
      class="flex flex-wrap items-center gap-x-4 gap-y-1.5 py-2 px-1 hover:bg-base-200/40 transition-colors text-sm"
    >
      <span class="w-24 shrink-0">
        <span class={["badge badge-sm", @meta.badge]}>{@meta.label}</span>
      </span>

      <span class="w-64 min-w-0 shrink">
        <span class="flex items-baseline gap-2">
          <span class="truncate">{@variant.pilot || @variant.deck.name}</span>
          <span :if={@variant.finish} class="text-xs italic text-base-content/50 shrink-0">
            {@variant.finish}
          </span>
          <span :if={@variant.record} class="text-xs text-base-content/55 tabular-nums shrink-0">
            {@variant.record}
          </span>
        </span>
        <span
          :if={@variant.event_name}
          class="block text-xs text-base-content/40 truncate"
        >
          {@variant.event_name}
          <span :if={@variant.event_date}>
            · {NetdecksHelpers.format_event_date(@variant.event_date)}
          </span>
        </span>
      </span>

      <%!-- What this list changes vs. the archetype core, inline as one
            wrapping strip of art chips in broad-type order (UIDR-017);
            the card name and delta live in the tooltip. Below lg the
            strip drops to its own line under the header. --%>
      <div class="order-last basis-full lg:order-none lg:basis-0 lg:flex-1 min-w-0 flex flex-wrap items-center gap-1.5">
        <div
          :for={entry <- Enum.flat_map(@delta_sections, &elem(&1, 1))}
          class="relative"
          title={"#{entry.name} #{NetdecksHelpers.matrix_delta_label(entry.delta)} vs. the core"}
        >
          <.card_image
            id={"delta-#{@variant.deck.id}-#{entry.arena_id}"}
            arena_id={entry.arena_id}
            variant={:art}
            class={"w-16 h-10 object-cover rounded border #{if entry.delta > 0, do: "border-success/40", else: "border-error/30"}"}
            cached_ids={@cached_ids}
          />
          <%!-- Craft pip (UIDR-017): on an added chip you don't fully own, the
                copies you'd craft + their wildcard rarity. Top-left so it never
                collides with the bottom-right delta badge. --%>
          <span
            :if={
              entry.delta > 0 and entry.missing > 0 and
                entry.rarity in ~w(common uncommon rare mythic)
            }
            class="absolute -top-1 -left-1 z-10 flex items-center gap-0.5 rounded bg-black/80 px-1 text-[10px] font-bold text-base-content tabular-nums"
            title={"Craft #{entry.missing} · #{entry.rarity} wildcard"}
          >
            {entry.missing}
            <.wildcard_icon rarity={entry.rarity} class="size-3" />
          </span>
          <span class={[
            "absolute -bottom-1 -right-1 rounded bg-black/80 px-1 text-[10px] font-bold tabular-nums",
            (entry.delta > 0 && "text-success") || "text-error/90"
          ]}>
            {NetdecksHelpers.matrix_delta_label(entry.delta)}
          </span>
        </div>
      </div>

      <span
        :if={NetdecksHelpers.any_cost?(@variant.result.maindeck.wildcard_cost)}
        class="ml-auto lg:ml-0 shrink-0"
      >
        <.cost_pips cost={@variant.result.maindeck.wildcard_cost} size="size-3.5" />
      </span>
    </.link>
    """
  end

  # ── Detail view ──────────────────────────────────────────────────────────

  attr :detail, :map, required: true
  attr :cached_ids, :any, required: true
  attr :prefs, DeckRendering.CompositionPrefs, required: true

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
        <span
          :if={NetdecksHelpers.source_archetype_note(@detail.deck, @detail.label)}
          class="badge badge-sm badge-ghost"
        >
          {NetdecksHelpers.source_archetype_note(@detail.deck, @detail.label)}
        </span>
        <span>via {@detail.deck.source_name}</span>
        <span :if={@detail.deck.fetched_at}>
          · {NetdecksHelpers.relative_time(@detail.deck.fetched_at)}
        </span>
      </div>
    </div>

    <div class="grid lg:grid-cols-[20rem_1fr] gap-6">
      <%!-- Craft summary + mana curve --%>
      <div class="space-y-4 self-start">
        <div class="bg-base-200 rounded-xl p-5 space-y-4">
          <%!-- Craft cost is split maindeck vs. sideboard, both always shown
                when present. Buildability status (short/craftable) keys off the
                maindeck only, so the sideboard is purely informational. --%>
          <div>
            <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-widest mb-2">
              Maindeck — to craft
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
              You own the full maindeck.
            </p>
            <p
              :if={@detail.result.status == :short}
              class="text-xs text-warning mt-2 flex items-center gap-2"
            >
              Still need <.cost_pips cost={@detail.result.maindeck.shortfall} />
              beyond your wildcards.
            </p>
            <p :if={@detail.result.status == :craftable} class="text-xs text-info mt-2">
              You have the wildcards to craft this now.
            </p>
          </div>

          <div :if={@detail.result.sideboard.total_copies > 0}>
            <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-widest mb-2">
              Sideboard — to craft
            </h3>
            <.cost_pips
              :if={NetdecksHelpers.any_cost?(@detail.result.sideboard.wildcard_cost)}
              cost={@detail.result.sideboard.wildcard_cost}
            />
            <p
              :if={!NetdecksHelpers.any_cost?(@detail.result.sideboard.wildcard_cost)}
              class="text-sm text-success"
            >
              You own the full sideboard.
            </p>
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

        <.mana_curve_chart
          :if={DeckRendering.card_count(@detail.deck.main_deck) > 0}
          id="netdeck-curve"
          cards={@detail.deck.main_deck}
          cards_by_arena_id={@detail.cards_by_arena_id}
          class="w-full rounded-xl bg-base-200"
        />
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
          show_curve={false}
          prefs={@prefs}
          card_class={missing_card_tint(@rows_by_arena_id)}
          count_entry={NetdecksHelpers.ownership_count_entry(@rows_by_arena_id)}
        >
          <:card_overlay :let={card}>
            <.ownership_wash row={Map.get(@rows_by_arena_id, card.arena_id)} />
          </:card_overlay>
        </.standard_composition>

        <.variants_list
          :if={length(@detail.variants) > 1}
          variants={@detail.variants}
          current_deck_id={@detail.deck.id}
        />

        <.variant_matrix matrix={@detail.matrix} />
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

  # Row-tint function for the text deck listing: cards with unowned
  # copies render in warning tone.
  defp missing_card_tint(rows_by_arena_id) do
    fn card ->
      NetdecksHelpers.missing_row_class(Map.get(rows_by_arena_id, card.arena_id))
    end
  end

  # Ownership annotation rendered over every card in the standard deck
  # composition: unowned copies dim the card. Counts render in the deck
  # view's gutter rail / splay badge via `ownership_count_entry` (UIDR-015)
  # so nothing printed on the card is ever covered.
  attr :row, :map, default: nil

  defp ownership_wash(assigns) do
    ~H"""
    <div
      :if={@row && @row.missing > 0}
      class="absolute inset-0 rounded-sm bg-base-100/60 pointer-events-none"
      title={NetdecksHelpers.ownership_title(@row)}
    />
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

  # Loads an archetype's display extras (core + deltas) and requests their
  # images: full cards for the core stacks, art crops for the delta chips.
  defp assign_archetype(socket, group) do
    extras = NetDecking.archetype_detail(group)

    delta_ids =
      extras.deltas_by_deck_id
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.arena_id)

    arena_ids = Enum.uniq(Enum.map(extras.core, & &1.arena_id) ++ delta_ids)

    socket
    |> assign(archetype: group, archetype_extras: extras)
    |> CardImages.request(arena_ids, variants: [:art, :full])
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

  # ── Recent view (UIDR-018) ───────────────────────────────────────────────

  defp view_from_params(%{"view" => "recent"}), do: "recent"
  defp view_from_params(_params), do: "status"

  defp parse_page(nil), do: 1
  defp parse_page(page) when is_binary(page), do: max(1, String.to_integer(page))

  defp netdecks_path("status", _page), do: ~p"/netdecks"

  defp netdecks_path("recent", page) do
    params =
      if page > 1,
        do: %{"view" => "recent", "page" => to_string(page)},
        else: %{"view" => "recent"}

    ~p"/netdecks?#{params}"
  end

  # Loads whichever tab's data the current view needs and requests its hero
  # art (both variants: art crop for the row thumbnail, full card for the
  # hover popup, matching every other card-image request in this module).
  defp assign_view_content(socket, "recent", page, _catalog) do
    # TODO(Task 7): read the browsed format from assigns, not this literal.
    recent = NetDecking.recent_decks("Standard", page, @per_page)

    art_ids =
      recent.entries
      |> Enum.map(fn entry -> List.first(entry.signature_arena_ids) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    socket
    |> assign(recent: recent)
    |> CardImages.request(art_ids, variants: [:art, :full])
  end

  defp assign_view_content(socket, "status", _page, catalog) do
    art_ids =
      [catalog.buildable, catalog.craftable, catalog.short]
      |> Enum.concat()
      |> Enum.map(fn group -> List.first(group.signature_arena_ids) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    socket
    |> assign(recent: nil)
    |> CardImages.request(art_ids, variants: [:art, :full])
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: String.trim(value) |> presence_trimmed()

  defp presence_trimmed(""), do: nil
  defp presence_trimmed(value), do: value
end
