defmodule Scry2Web.CardsLive do
  @moduledoc """
  Visual card browser for Scry2.

  Provides MTGA-style search and filtering: text search, mana color toggles,
  and a slide-out filter drawer (Rarity, Mana Value, Card Type). Results are
  capped at 100 with a total count shown.

  Also shows Data Sources storage stats and Import Controls for triggering
  17lands and Scryfall refreshes.
  """

  use Scry2Web, :live_view

  import Ecto.Query, only: [from: 2]

  alias Scry2.{Cards, Console, Repo, Topics}
  alias Scry2.Cards.ImageCache
  alias Scry2.Workers.{PeriodicallyBackfillArenaIds, PeriodicallyUpdateCards}
  alias Scry2Web.CardsHelpers, as: Helpers

  @result_cap 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.cards_updates())
      Console.subscribe()
    end

    {:ok,
     socket
     |> assign(:search, "")
     |> assign(:colors, MapSet.new())
     |> assign(:rarities, MapSet.new())
     |> assign(:mana_values, MapSet.new())
     |> assign(:types, MapSet.new())
     |> assign(:filter_open, false)
     |> assign(:results, [])
     |> assign(:result_total, 0)
     |> assign(:cached_arena_ids, MapSet.new())
     |> assign(:import_log, [])
     |> assign(:data_stats, Cards.data_source_stats())
     |> assign(:import_status, load_import_status())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:search, Helpers.decode_search(params))
     |> assign(:colors, Helpers.decode_colors(params))
     |> assign(:rarities, Helpers.decode_rarities(params))
     |> assign(:mana_values, Helpers.decode_mana_values(params))
     |> assign(:types, Helpers.decode_types(params))
     |> run_search()}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(:search, search) |> push_filter_patch()}
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(:search, "") |> push_filter_patch()}
  end

  @impl true
  def handle_event("toggle_color", %{"color" => color}, socket) do
    {:noreply, socket |> update(:colors, &toggle_set(&1, color)) |> push_filter_patch()}
  end

  @impl true
  def handle_event("toggle_filter", _params, socket) do
    {:noreply, update(socket, :filter_open, &(!&1))}
  end

  @impl true
  def handle_event("close_filter", _params, socket) do
    {:noreply, assign(socket, :filter_open, false)}
  end

  @impl true
  def handle_event("toggle_rarity", %{"rarity" => rarity}, socket) do
    {:noreply, socket |> update(:rarities, &toggle_set(&1, rarity)) |> push_filter_patch()}
  end

  @impl true
  def handle_event("toggle_mana_value", %{"value" => value}, socket) do
    parsed = Helpers.parse_mana_value(value)
    {:noreply, socket |> update(:mana_values, &toggle_set(&1, parsed)) |> push_filter_patch()}
  end

  @impl true
  def handle_event("toggle_type", %{"type" => type}, socket) do
    type_atom = String.to_existing_atom(type)
    {:noreply, socket |> update(:types, &toggle_set(&1, type_atom)) |> push_filter_patch()}
  end

  @impl true
  def handle_event("clear_all_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:colors, MapSet.new())
     |> assign(:rarities, MapSet.new())
     |> assign(:mana_values, MapSet.new())
     |> assign(:types, MapSet.new())
     |> push_filter_patch()}
  end

  @impl true
  def handle_event("refresh_17lands", _params, socket) do
    {:ok, _job} = %{} |> PeriodicallyUpdateCards.new() |> Oban.insert()
    Process.send_after(self(), :poll_import_status, 2_000)

    {:noreply,
     socket
     |> update(:import_status, &%{&1 | lands17_running: true})
     |> assign(:import_log, [])}
  end

  @impl true
  def handle_event("refresh_scryfall", _params, socket) do
    {:ok, _job} = %{} |> PeriodicallyBackfillArenaIds.new() |> Oban.insert()
    Process.send_after(self(), :poll_import_status, 2_000)

    {:noreply,
     socket
     |> update(:import_status, &%{&1 | scryfall_running: true})
     |> assign(:import_log, [])}
  end

  @impl true
  def handle_info({:cards_refreshed, _count}, socket) do
    {:noreply,
     socket
     |> assign(:import_log, [])
     |> assign(:data_stats, Cards.data_source_stats())
     |> assign(:import_status, load_import_status())
     |> run_search()}
  end

  @impl true
  def handle_info({:arena_ids_backfilled, _count}, socket) do
    {:noreply,
     socket
     |> assign(:import_log, [])
     |> assign(:import_status, load_import_status())}
  end

  @impl true
  def handle_info({:log_entry, %Console.Entry{component: :importer} = entry}, socket) do
    log = [entry.message | socket.assigns.import_log] |> Enum.take(3)
    {:noreply, assign(socket, :import_log, log)}
  end

  @impl true
  def handle_info({:log_entry, _entry}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:poll_import_status, socket) do
    status = load_import_status()

    if status.lands17_running or status.scryfall_running do
      Process.send_after(self(), :poll_import_status, 3_000)
    end

    {:noreply, assign(socket, :import_status, status)}
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:cache_images, {:ok, _stats}, socket) do
    arena_ids = socket.assigns.results |> Enum.map(& &1.arena_id) |> Enum.filter(& &1)
    cached = arena_ids |> Enum.filter(&ImageCache.cached?/1) |> MapSet.new()
    {:noreply, assign(socket, :cached_arena_ids, cached)}
  end

  @impl true
  def handle_async(:cache_images, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id} current_path={@player_scope_uri}>
      <%!-- Search bar row --%>
      <div class="flex items-center gap-3">
        <form phx-change="search" phx-submit="search" class="relative flex-1">
          <input
            type="text"
            name="search"
            placeholder="Search cards..."
            value={@search}
            phx-debounce="150"
            class="input input-bordered w-full pr-8"
          />
          <button
            :if={@search != ""}
            phx-click="clear_search"
            class="absolute right-2 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-base-content"
            aria-label="Clear search"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </form>

        <%!-- Mana color toggles --%>
        <div class="flex items-center gap-1">
          <.color_toggle color="W" active={MapSet.member?(@colors, "W")} />
          <.color_toggle color="U" active={MapSet.member?(@colors, "U")} />
          <.color_toggle color="B" active={MapSet.member?(@colors, "B")} />
          <.color_toggle color="R" active={MapSet.member?(@colors, "R")} />
          <.color_toggle color="G" active={MapSet.member?(@colors, "G")} />
          <.color_toggle color="M" active={MapSet.member?(@colors, "M")} />
          <.color_toggle color="C" active={MapSet.member?(@colors, "C")} />
        </div>

        <%!-- Filter drawer toggle --%>
        <button
          phx-click="toggle_filter"
          class={[
            "btn btn-square btn-sm",
            if(filter_active?(@rarities, @mana_values, @types),
              do: "btn-primary",
              else: "btn-ghost"
            )
          ]}
          aria-label="Advanced filters"
        >
          <.icon name="hero-adjustments-horizontal" class="size-4" />
        </button>
      </div>

      <%!-- Results area or empty state --%>
      <div :if={not search_active?(@search, @colors, @rarities, @mana_values, @types)}>
        <div class="py-8 text-base-content/50 text-sm space-y-1">
          <p>
            Search by name using the text field, or click the colored mana symbols to filter by color.
          </p>
          <p>
            Use the <.icon name="hero-adjustments-horizontal" class="size-3 inline" />
            filter icon to narrow by rarity, mana value, or card type.
          </p>
          <p>Results are capped at 100 — refine your search to find specific cards.</p>
        </div>
      </div>

      <div :if={search_active?(@search, @colors, @rarities, @mana_values, @types)}>
        <p class="text-sm text-base-content/50">
          Showing <span class="font-medium text-base-content">{length(@results)}</span>
          of <span class="font-medium text-base-content">{@result_total}</span>
          cards <span :if={@result_total > 100}> — refine to see more</span>
        </p>

        <div
          :if={@results == []}
          class="py-8 text-center text-base-content/40 text-sm"
        >
          No cards match your filters.
        </div>

        <div
          :if={@results != []}
          class="grid gap-2"
          style="grid-template-columns: repeat(auto-fill, minmax(7.5rem, 1fr))"
        >
          <div :for={card <- @results} class="flex flex-col gap-1">
            <.card_image
              arena_id={card.arena_id || 0}
              name={card.name}
              class="w-full"
              cached={MapSet.member?(@cached_arena_ids, card.arena_id || 0)}
            />
            <.card_name
              arena_id={card.arena_id || 0}
              name={card.name}
              id={"card-name-#{card.id}"}
              class="text-xs truncate"
              cached={MapSet.member?(@cached_arena_ids, card.arena_id || 0)}
            />
            <.rarity_badge rarity={card.rarity} />
          </div>
        </div>
      </div>

      <%!-- Bottom panels --%>
      <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
        <%!-- Data Sources panel --%>
        <div class="bg-base-200 rounded-xl p-6 space-y-4">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Data Sources
          </h2>

          <.source_row
            label="17lands"
            color="#3b82f6"
            count={@data_stats.lands17_count}
            count_label="cards"
            bytes={@data_stats.lands17_bytes}
          />
          <.source_row
            label="Scryfall"
            color="#8b5cf6"
            count={@data_stats.scryfall_count}
            count_label="records"
            bytes={@data_stats.scryfall_bytes}
          />
          <.source_row
            label="Card Images"
            color="#10b981"
            count={@data_stats.image_count}
            count_label="files"
            bytes={@data_stats.image_bytes}
          />
          <.source_row label="App Database" color="#f59e0b" bytes={@data_stats.db_bytes} />

          <.storage_bar segments={[
            {"17lands", "#3b82f6", @data_stats.lands17_bytes},
            {"Scryfall", "#8b5cf6", @data_stats.scryfall_bytes},
            {"Card Images", "#10b981", @data_stats.image_bytes},
            {"App Database", "#f59e0b", @data_stats.db_bytes}
          ]} />
        </div>

        <%!-- Import Controls panel --%>
        <div class="bg-base-200 rounded-xl p-6 space-y-4">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Import Controls
          </h2>

          <.import_row
            label="17lands card data"
            description="Card names, colors, types from 17lands public dataset"
            updated_at={@import_status.lands17_updated_at}
            running={@import_status.lands17_running}
            event="refresh_17lands"
            log_lines={@import_log}
          />

          <.import_row
            label="Scryfall arena IDs"
            description="Backfills MTGA arena IDs from Scryfall bulk data"
            updated_at={@import_status.scryfall_updated_at}
            running={@import_status.scryfall_running}
            event="refresh_scryfall"
            log_lines={@import_log}
          />

          <div class="border-t border-base-300 pt-3 text-xs text-base-content/40">
            Queue:
            <span class={
              if Enum.any?([@import_status.lands17_running, @import_status.scryfall_running]),
                do: "text-warning",
                else: "text-success"
            }>
              {if Enum.any?([@import_status.lands17_running, @import_status.scryfall_running]),
                do: "running",
                else: "idle"}
            </span>
          </div>
        </div>
      </div>

      <%!-- Filter drawer overlay --%>
      <div
        :if={@filter_open}
        class="fixed inset-0 z-40 bg-black/30"
        phx-click="close_filter"
      />

      <div class={[
        "fixed top-0 right-0 h-full w-[22.5rem] bg-base-200 z-50 shadow-2xl",
        "flex flex-col transition-transform duration-300",
        if(@filter_open, do: "translate-x-0", else: "translate-x-full")
      ]}>
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h2 class="font-semibold">Advanced Filters</h2>
          <button phx-click="close_filter" class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div class="flex-1 overflow-y-auto p-4 space-y-6">
          <%!-- Rarity --%>
          <div class="space-y-2">
            <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Rarity
            </h3>
            <div class="flex flex-wrap gap-2">
              <.filter_toggle
                :for={rarity <- ~w(common uncommon rare mythic)}
                active={MapSet.member?(@rarities, rarity)}
                event="toggle_rarity"
                value={rarity}
              >
                <.rarity_badge rarity={rarity} />
                <span class="ml-1">{String.capitalize(rarity)}</span>
              </.filter_toggle>
            </div>
          </div>

          <%!-- Mana Value --%>
          <div class="space-y-2">
            <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Mana Value
            </h3>
            <div class="flex flex-wrap gap-2">
              <.filter_toggle
                :for={mv <- [0, 1, 2, 3, 4, 5, 6]}
                active={MapSet.member?(@mana_values, mv)}
                event="toggle_mana_value"
                value={to_string(mv)}
              >
                {mv}
              </.filter_toggle>
              <.filter_toggle
                active={MapSet.member?(@mana_values, :seven_plus)}
                event="toggle_mana_value"
                value="seven_plus"
              >
                7+
              </.filter_toggle>
            </div>
          </div>

          <%!-- Card Type --%>
          <div class="space-y-2">
            <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Card Type
            </h3>
            <div class="flex flex-wrap gap-2">
              <.filter_toggle
                :for={
                  {label, type} <- [
                    {"Creature", "creature"},
                    {"Instant", "instant"},
                    {"Sorcery", "sorcery"},
                    {"Enchantment", "enchantment"},
                    {"Artifact", "artifact"},
                    {"Planeswalker", "planeswalker"},
                    {"Land", "land"},
                    {"Battle", "battle"}
                  ]
                }
                active={MapSet.member?(@types, String.to_existing_atom(type))}
                event="toggle_type"
                value={type}
              >
                <.mana_symbol symbol={type} class="ms-fw" />
                <span class="ml-1">{label}</span>
              </.filter_toggle>
            </div>
          </div>
        </div>

        <div class="p-4 border-t border-base-300">
          <button
            phx-click="clear_all_filters"
            class="btn btn-ghost btn-sm w-full"
          >
            Clear all filters
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Function components ─────────────────────────────────────────────────

  attr :color, :string, required: true
  attr :active, :boolean, required: true

  defp color_toggle(assigns) do
    ~H"""
    <button
      phx-click="toggle_color"
      phx-value-color={@color}
      class={[
        "rounded-full p-0.5 transition-all",
        if(@active,
          do: "ring-2 ring-primary ring-offset-1 ring-offset-base-100",
          else: "opacity-60 hover:opacity-100"
        )
      ]}
      aria-label={"Filter by #{@color}"}
      aria-pressed={to_string(@active)}
    >
      <.mana_symbol symbol={color_symbol(@color)} cost size="2x" />
    </button>
    """
  end

  attr :label, :string, required: true
  attr :bytes, :integer, required: true
  attr :color, :string, required: true
  attr :count, :integer, default: nil
  attr :count_label, :string, default: nil

  defp source_row(assigns) do
    ~H"""
    <div class="flex justify-between text-sm">
      <span class="flex items-center gap-2 font-medium">
        <span class="size-2 rounded-full shrink-0" style={"background-color: #{@color}"} />
        {@label}
      </span>
      <span class="text-base-content/60">
        <span :if={@count != nil}>{Helpers.format_count(@count)} {@count_label} · </span>{Helpers.format_bytes(
          @bytes
        )}
      </span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :description, :string, required: true
  attr :updated_at, :any, required: true
  attr :running, :boolean, required: true
  attr :event, :string, required: true
  attr :log_lines, :list, default: []

  defp import_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4">
      <div class="min-w-0 flex-1">
        <p class="font-medium text-sm">{@label}</p>
        <p class="text-xs text-base-content/40 mt-0.5">{@description}</p>
        <p class="text-xs text-base-content/50 mt-1">
          Last updated: {format_datetime(@updated_at)}
        </p>
        <p
          :if={@running and @log_lines != []}
          class="text-xs font-mono text-base-content/40 mt-1 truncate"
        >
          ↳ {hd(@log_lines)}
        </p>
      </div>
      <div class="flex items-center gap-2 shrink-0">
        <button
          phx-click={@event}
          class="btn btn-outline btn-xs"
          disabled={@running}
        >
          <.icon name="hero-arrow-path" class={["size-3", if(@running, do: "animate-spin")]} />
          {if @running, do: "Running...", else: "Refresh"}
        </button>
        <div class={["size-2 rounded-full", Helpers.oban_status_class(@running)]} />
      </div>
    </div>
    """
  end

  # Each segment: {label, hex_color, bytes}
  attr :segments, :list, required: true

  defp storage_bar(assigns) do
    total = Enum.sum(Enum.map(assigns.segments, fn {_, _, b} -> b end))
    assigns = assign(assigns, :total, total)

    ~H"""
    <div class="h-2 rounded-full overflow-hidden flex gap-px mt-2">
      <div
        :for={{_label, color, bytes} <- @segments}
        class="h-full transition-all"
        style={"background-color: #{color}; width: #{if @total > 0, do: round(bytes / @total * 100), else: 0}%"}
      />
    </div>
    """
  end

  attr :active, :boolean, required: true
  attr :event, :string, required: true
  attr :value, :string, required: true
  slot :inner_block, required: true

  defp filter_toggle(assigns) do
    ~H"""
    <button
      phx-click={@event}
      phx-value-rarity={if @event == "toggle_rarity", do: @value}
      phx-value-value={if @event == "toggle_mana_value", do: @value}
      phx-value-type={if @event == "toggle_type", do: @value}
      class={[
        "btn btn-xs",
        if(@active, do: "btn-primary", else: "btn-ghost border border-base-300")
      ]}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp push_filter_patch(socket) do
    %{search: search, colors: colors, rarities: rarities, mana_values: mana_values, types: types} =
      socket.assigns

    params = Helpers.params_from_filters(search, colors, rarities, mana_values, types)
    push_patch(socket, to: ~p"/cards?#{params}")
  end

  defp run_search(socket) do
    %{
      search: search,
      colors: colors,
      rarities: rarities,
      mana_values: mana_values,
      types: types
    } = socket.assigns

    if Helpers.any_filter_active?(search, colors, rarities, mana_values, types) do
      filters = %{
        name_like: Helpers.blank_to_nil(search),
        colors: colors,
        rarity: Helpers.rarity_filter(rarities),
        mana_values: mana_values,
        types: types,
        limit: @result_cap
      }

      total = Cards.count_cards(filters)
      results = Cards.list_cards(filters)

      arena_ids = results |> Enum.map(& &1.arena_id) |> Enum.filter(& &1)
      cached = arena_ids |> Enum.filter(&ImageCache.cached?/1) |> MapSet.new()

      socket
      |> assign(:results, results)
      |> assign(:result_total, total)
      |> assign(:cached_arena_ids, cached)
      |> start_async(:cache_images, fn -> ImageCache.ensure_cached(arena_ids) end)
    else
      socket
      |> assign(:results, [])
      |> assign(:result_total, 0)
      |> assign(:cached_arena_ids, MapSet.new())
    end
  end

  defp toggle_set(set, value) do
    if MapSet.member?(set, value),
      do: MapSet.delete(set, value),
      else: MapSet.put(set, value)
  end

  defp search_active?(search, colors, rarities, mana_values, types) do
    Helpers.any_filter_active?(search, colors, rarities, mana_values, types)
  end

  defp filter_active?(rarities, mana_values, types) do
    not MapSet.equal?(rarities, MapSet.new()) or
      not MapSet.equal?(mana_values, MapSet.new()) or
      not MapSet.equal?(types, MapSet.new())
  end

  defp load_import_status do
    timestamps = Cards.import_timestamps()

    %{
      lands17_updated_at: timestamps.lands17_updated_at,
      scryfall_updated_at: timestamps.scryfall_updated_at,
      lands17_running: oban_running?(PeriodicallyUpdateCards),
      scryfall_running: oban_running?(PeriodicallyBackfillArenaIds)
    }
  end

  defp oban_running?(worker) do
    worker_name = to_string(worker)

    Repo.exists?(
      from(j in Oban.Job,
        where: j.worker == ^worker_name and j.state in ["available", "executing", "scheduled"]
      )
    )
  end

  defp color_symbol("W"), do: "w"
  defp color_symbol("U"), do: "u"
  defp color_symbol("B"), do: "b"
  defp color_symbol("R"), do: "r"
  defp color_symbol("G"), do: "g"
  defp color_symbol("M"), do: "multicolor"
  defp color_symbol("C"), do: "c"
end
