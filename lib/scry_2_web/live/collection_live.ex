defmodule Scry2Web.CollectionLive do
  @moduledoc """
  LiveView for the memory-read card collection (ADR 034).

  Three states:

    * **disabled** — the memory reader is off by default; shows the
      disclosure banner and an "Enable memory reader" button. Until
      the user enables the feature, no memory access happens.
    * **enabled, no snapshot** — reader enabled but no collection has
      been captured yet; shows a refresh CTA.
    * **enabled, with snapshot** — shows the latest snapshot summary
      (card count, total copies, reader confidence, last refresh) and,
      when a previous snapshot exists, a "Recent acquisitions" panel
      derived from the latest `Scry2.Collection.Diff` row.

  Subscribes to `Scry2.Topics.collection_snapshots/0` and
  `Scry2.Topics.collection_diffs/0` so a successful refresh and its
  computed delta both update the view in-place.
  """

  use Scry2Web, :live_view

  alias Scry2.Cards
  alias Scry2.Collection
  alias Scry2.Collection.DiffView
  alias Scry2.Topics

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.collection_snapshots())
      Topics.subscribe(Topics.collection_diffs())
    end

    diff = Collection.latest_diff()

    {:ok,
     assign(socket,
       reader_enabled: Collection.reader_enabled?(),
       snapshot: Collection.current(),
       latest_diff: diff,
       diff_cards: cards_for(diff),
       refreshing: false,
       last_error: nil
     )}
  end

  @impl true
  def handle_event("enable_reader", _params, socket) do
    :ok = Collection.enable_reader!()
    {:noreply, assign(socket, reader_enabled: true)}
  end

  def handle_event("disable_reader", _params, socket) do
    :ok = Collection.disable_reader!()

    {:noreply,
     socket
     |> assign(reader_enabled: false, refreshing: false, last_error: nil)
     |> put_flash(:info, "Memory reader disabled.")}
  end

  def handle_event("refresh", _params, socket) do
    case Collection.refresh(trigger: "manual") do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(refreshing: true, last_error: nil)
         # In inline-Oban (tests) the job has already run; reload now so
         # the snapshot/state assigns reflect reality. In async-Oban
         # (prod) we'll get the snapshot_saved broadcast instead.
         |> reload_after_refresh()}

      {:error, reason} ->
        {:noreply, assign(socket, refreshing: false, last_error: friendly_error(reason))}
    end
  end

  @impl true
  def handle_info({:snapshot_saved, snapshot}, socket) do
    {:noreply,
     socket
     |> assign(snapshot: snapshot, refreshing: false, last_error: nil)
     |> put_flash(:info, "Collection refreshed (#{snapshot.card_count} cards).")}
  end

  def handle_info({:diff_saved, diff}, socket) do
    {:noreply, assign(socket, latest_diff: diff, diff_cards: cards_for(diff))}
  end

  def handle_info({:refresh_failed, reason}, socket) do
    {:noreply, assign(socket, refreshing: false, last_error: friendly_error(reason))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp cards_for(nil), do: %{}

  defp cards_for(diff) do
    diff |> DiffView.arena_ids() |> Cards.list_by_arena_ids()
  end

  defp friendly_error(:mtga_not_running),
    do: "MTGA is not running. Start the game, then click Refresh now."

  defp friendly_error(:no_cards_array_found),
    do:
      "Could not locate the card collection in MTGA memory. Try again after opening your collection screen in MTGA."

  defp friendly_error({:check, _}),
    do:
      "MTGA memory layout did not match expectations. It may have changed in a recent game update."

  defp friendly_error(other), do: "Reader failed: #{inspect(other)}"

  defp reload_after_refresh(socket) do
    assign(socket, snapshot: Collection.current(), refreshing: false)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <h1 class="text-2xl font-semibold mb-6 font-beleren">Collection</h1>

      <%= if @reader_enabled do %>
        <.enabled_view
          snapshot={@snapshot}
          latest_diff={@latest_diff}
          diff_cards={@diff_cards}
          refreshing={@refreshing}
          last_error={@last_error}
        />
      <% else %>
        <.disabled_view />
      <% end %>
    </Layouts.app>
    """
  end

  # --- view helpers ---

  attr :rest, :global

  defp disabled_view(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300 max-w-3xl" data-role="collection-disabled">
      <div class="card-body space-y-4">
        <h2 class="card-title">Memory reader is off</h2>
        <p class="text-sm opacity-80">
          Scry&nbsp;2 can read your full MTGA collection (including cards you have never
          played) directly from the running MTGA process. This requires scanning the
          game's memory while it is running.
        </p>
        <p class="text-sm opacity-80">
          No files are modified. No data leaves your machine. You can disable the reader
          at any time; nothing else in Scry&nbsp;2 depends on it.
        </p>
        <div class="card-actions justify-end">
          <button class="btn btn-primary btn-sm" phx-click="enable_reader">
            Enable memory reader
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :snapshot, :any, required: true
  attr :latest_diff, :any, required: true
  attr :diff_cards, :map, required: true
  attr :refreshing, :boolean, required: true
  attr :last_error, :any, required: true

  defp enabled_view(assigns) do
    ~H"""
    <div class="space-y-6" data-role="collection-enabled">
      <div class="flex items-center gap-3">
        <button
          class="btn btn-soft btn-primary btn-sm"
          phx-click="refresh"
          disabled={@refreshing}
        >
          <span :if={@refreshing}>Refreshing…</span>
          <span :if={not @refreshing}>Refresh now</span>
        </button>
        <button class="btn btn-ghost btn-sm" phx-click="disable_reader">
          Disable reader
        </button>
        <.link navigate={~p"/collection/diagnostics"} class="btn btn-ghost btn-sm">
          Diagnostics
        </.link>
      </div>

      <div
        :if={@last_error}
        class="alert alert-soft alert-warning max-w-3xl"
        data-role="collection-error"
      >
        <span>{@last_error}</span>
      </div>

      <%= if @snapshot do %>
        <.snapshot_card snapshot={@snapshot} />
      <% else %>
        <div class="card bg-base-200 border border-base-300 max-w-xl" data-role="no-snapshot">
          <div class="card-body">
            <p class="text-sm opacity-80">
              No snapshot yet. Make sure MTGA is running, then click <strong>Refresh now</strong> .
            </p>
          </div>
        </div>
      <% end %>

      <.diff_card :if={@latest_diff} diff={@latest_diff} cards={@diff_cards} />
    </div>
    """
  end

  attr :diff, :any, required: true
  attr :cards, :map, required: true

  defp diff_card(assigns) do
    assigns =
      assign(assigns,
        acquired: DiffView.entries(assigns.diff.cards_added_json, assigns.cards),
        removed: DiffView.entries(assigns.diff.cards_removed_json, assigns.cards)
      )

    ~H"""
    <div class="card bg-base-200 border border-base-300 max-w-3xl" data-role="diff-card">
      <div class="card-body">
        <h2 class="card-title">Recent acquisitions</h2>
        <p
          class="text-xs text-base-content/60"
          title={Calendar.strftime(@diff.inserted_at, "%Y-%m-%d %H:%M UTC")}
        >
          {relative_time(@diff.inserted_at)} · +{@diff.total_acquired} · −{@diff.total_removed}
        </p>

        <div :if={@acquired != []} class="mt-3">
          <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Acquired</div>
          <ul class="space-y-1" data-role="diff-acquired">
            <li :for={entry <- @acquired} class="flex items-center gap-2 text-sm">
              <span class="badge badge-soft badge-success badge-sm tabular-nums">
                +{entry.count}
              </span>
              <span class="truncate">{entry.name}</span>
            </li>
          </ul>
        </div>

        <div :if={@removed != []} class="mt-3">
          <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Removed</div>
          <ul class="space-y-1" data-role="diff-removed">
            <li :for={entry <- @removed} class="flex items-center gap-2 text-sm">
              <span class="badge badge-soft badge-warning badge-sm tabular-nums">
                −{entry.count}
              </span>
              <span class="truncate">{entry.name}</span>
            </li>
          </ul>
        </div>

        <div :if={@acquired == [] and @removed == []} class="mt-3 text-sm text-base-content/60">
          No card changes since the previous snapshot.
        </div>
      </div>
    </div>
    """
  end

  attr :snapshot, :any, required: true

  defp snapshot_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300 max-w-3xl" data-role="snapshot-card">
      <div class="card-body">
        <h2 class="card-title">Latest snapshot</h2>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mt-4">
          <.stat label="Cards" value={format_number(@snapshot.card_count)} key="card-count" />
          <.stat
            label="Total copies"
            value={format_number(@snapshot.total_copies)}
            key="total-copies"
          />
          <.stat
            label="Reader path"
            value={humanize_reader(@snapshot.reader_confidence)}
            key="confidence"
            tone={:muted}
          />
          <.stat
            label="Captured"
            value={relative_time(@snapshot.snapshot_ts)}
            title={Calendar.strftime(@snapshot.snapshot_ts, "%Y-%m-%d %H:%M UTC")}
            key="captured-at"
            tone={:muted}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :key, :string, required: true
  attr :title, :string, default: nil
  attr :tone, :atom, default: :numeric, values: [:numeric, :muted]

  defp stat(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-lg p-4 min-w-0" data-stat={@key}>
      <div class="text-xs text-base-content/60">{@label}</div>
      <div class={["mt-1 truncate", stat_value_class(@tone)]} title={@title}>
        {@value}
      </div>
    </div>
    """
  end

  defp stat_value_class(:numeric), do: "text-2xl font-semibold tabular-nums"
  defp stat_value_class(:muted), do: "text-sm text-base-content/80"

  defp humanize_reader("walker"), do: "Direct read"
  defp humanize_reader("fallback_scan"), do: "Fallback scan"
  defp humanize_reader(other) when is_binary(other), do: String.replace(other, "_", " ")
  defp humanize_reader(_), do: "—"

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(other), do: to_string(other)
end
