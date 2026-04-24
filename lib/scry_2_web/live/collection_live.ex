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
      (card count, total copies, reader confidence, last refresh).

  Subscribes to `Scry2.Topics.collection_snapshots/0` so a successful
  refresh updates the view in-place.
  """

  use Scry2Web, :live_view

  alias Scry2.Collection
  alias Scry2.Topics

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.collection_snapshots())

    {:ok,
     assign(socket,
       reader_enabled: Collection.reader_enabled?(),
       snapshot: Collection.current(),
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

  def handle_info({:refresh_failed, reason}, socket) do
    {:noreply, assign(socket, refreshing: false, last_error: friendly_error(reason))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

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
        <.enabled_view snapshot={@snapshot} refreshing={@refreshing} last_error={@last_error} />
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
          <.stat label="Cards" value={@snapshot.card_count} key="card-count" />
          <.stat label="Total copies" value={@snapshot.total_copies} key="total-copies" />
          <.stat label="Reader path" value={@snapshot.reader_confidence} key="confidence" />
          <.stat
            label="Captured"
            value={Calendar.strftime(@snapshot.snapshot_ts, "%Y-%m-%d %H:%M UTC")}
            key="captured-at"
          />
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :key, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div class="stat bg-base-100 rounded-lg p-4" data-stat={@key}>
      <div class="stat-title text-xs opacity-70">{@label}</div>
      <div class="stat-value text-xl">{@value}</div>
    </div>
    """
  end
end
