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
  alias Scry2.Topics
  alias Scry2.Workers.PeriodicallyFetchNetdecks
  alias Scry2Web.NetdecksHelpers

  @empty_catalog %{buildable: [], craftable: [], short: []}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.collection_snapshots())

    {:ok, assign(socket, search: "", catalog: @empty_catalog, detail: nil, sources: [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case NetDecking.get_deck(id) do
      nil -> {:noreply, push_navigate(socket, to: ~p"/netdecks")}
      deck -> {:noreply, assign(socket, detail: NetDecking.deck_detail(deck))}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket, detail: nil, catalog: NetDecking.catalog(), sources: source_summary())}
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

  def handle_event("fetch_now", _params, socket) do
    Oban.insert(PeriodicallyFetchNetdecks.new(%{}))

    {:noreply,
     socket
     |> put_flash(:info, "Fetching decks from sources…")
     |> assign(catalog: NetDecking.catalog(), sources: source_summary())}
  end

  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, "Copied — switch to MTGA → Import in the Deck Builder.")}
  end

  def handle_event("copy_failed", _params, socket) do
    {:noreply,
     put_flash(socket, :error, "Couldn't reach the clipboard. Select the text to copy manually.")}
  end

  @impl true
  def handle_info({:snapshot_saved, _snapshot}, socket) do
    socket =
      if detail = socket.assigns.detail do
        assign(socket, detail: NetDecking.deck_detail(detail.deck))
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
      <.detail :if={@detail} detail={@detail} />
      <.catalog :if={is_nil(@detail)} catalog={@catalog} search={@search} sources={@sources} />
    </Layouts.app>
    """
  end

  # ── Catalog view ─────────────────────────────────────────────────────────

  attr :catalog, :map, required: true
  attr :search, :string, required: true
  attr :sources, :list, required: true

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
      <button type="button" phx-click="fetch_now" class="btn btn-xs btn-ghost gap-1">
        <.icon name="hero-arrow-path" class="size-3.5" /> Fetch now
      </button>
    </div>

    <details class="bg-base-200 rounded-xl mb-6 group">
      <summary class="cursor-pointer select-none px-4 py-3 text-sm font-medium flex items-center gap-2">
        <.icon name="hero-plus" class="size-4" /> Import a deck
      </summary>
      <form id="netdeck-import" phx-submit="import" class="px-4 pb-4 space-y-3">
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
    </details>

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

      <ul class="space-y-0.5">
        <li :for={entry <- entries}>
          <.link
            patch={~p"/netdecks/#{entry.deck.id}"}
            class="flex items-center gap-3 px-3 py-2 rounded-lg hover:bg-base-content/5 transition-colors"
          >
            <span class="font-medium truncate">{entry.deck.name}</span>
            <span :if={entry.deck.archetype} class="badge badge-sm badge-ghost shrink-0">
              {entry.deck.archetype}
            </span>
            <span
              :if={NetdecksHelpers.unresolved_count(entry.deck) > 0}
              class="tooltip shrink-0"
              data-tip={"#{NetdecksHelpers.unresolved_count(entry.deck)} card(s) not recognised"}
            >
              <.icon name="hero-exclamation-triangle" class="size-4 text-warning/80" />
            </span>
            <span class="flex-1"></span>
            <.cost_pips cost={entry.result.maindeck.wildcard_cost} />
            <span class="text-xs text-base-content/45 w-12 text-right shrink-0 tabular-nums">
              {NetdecksHelpers.format_owned_pct(entry.result.maindeck.owned_pct)}
            </span>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  # ── Detail view ──────────────────────────────────────────────────────────

  attr :detail, :map, required: true

  defp detail(assigns) do
    assigns =
      assign(assigns,
        meta: NetdecksHelpers.status_meta(assigns.detail.result.status),
        unresolved: NetdecksHelpers.unresolved_count(assigns.detail.deck)
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
        <h1 class="text-2xl font-beleren leading-tight">{@detail.deck.name}</h1>
        <span class={["badge badge-sm", @meta.badge]}>{@meta.label}</span>
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

      <%!-- Decklist --%>
      <div class="space-y-6">
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

        <.card_list title="Maindeck" rows={@detail.main_rows} />
        <.card_list :if={@detail.side_rows != []} title="Sideboard" rows={@detail.side_rows} />
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true

  defp card_list(assigns) do
    ~H"""
    <div>
      <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-widest mb-2">
        {@title}
      </h3>
      <ul class="divide-y divide-base-300/40">
        <li :for={row <- @rows} class="flex items-center gap-2 py-1.5 text-sm">
          <% state = NetdecksHelpers.card_row_state(row) %>
          <span class="w-6 text-right tabular-nums text-base-content/55">{row.needed}</span>
          <span class="flex-1 truncate">{row.name}</span>
          <.rarity_badge :if={row.rarity} rarity={row.rarity} />
          <span class={[
            "text-xs tabular-nums w-16 text-right shrink-0",
            NetdecksHelpers.card_row_tone(state)
          ]}>
            <%= if row.free? do %>
              basic
            <% else %>
              {row.owned}/{row.needed}
            <% end %>
          </span>
        </li>
      </ul>
    </div>
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

  defp catalog_total(catalog) do
    Enum.sum(Enum.map([:buildable, :craftable, :short], &length(catalog[&1] || [])))
  end

  defp source_summary do
    NetDecking.list_decks() |> NetdecksHelpers.source_summary()
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: String.trim(value) |> presence_trimmed()

  defp presence_trimmed(""), do: nil
  defp presence_trimmed(value), do: value
end
