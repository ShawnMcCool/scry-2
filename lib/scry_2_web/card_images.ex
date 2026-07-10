defmodule Scry2Web.CardImages do
  @moduledoc """
  The one way a LiveView gets card images onto disk and knows when
  they are ready.

  A page declares the arena_ids it renders; this module makes the
  image files locally available and maintains the socket assign the
  templates read. Pages never talk to `Scry2.Cards.ImageCache`
  directly and never define their own `handle_async` for downloads.

  ## Usage

      def handle_params(params, _uri, socket) do
        ...
        {:noreply, CardImages.request(socket, arena_ids)}
      end

      # netdecks catalog tiles show art crops and full-card hovers:
      CardImages.request(socket, arena_ids, variants: [:art, :full])

  Templates thread the managed assign into `CardComponents.card_image/1`:

      <.card_image arena_id={id} cached_ids={@cached_card_ids} />

  ## Managed assigns

    * `@cached_card_ids` — `%{full: MapSet, art: MapSet}` of arena_ids
      whose image file is on disk. Monotonic: ids are only ever added,
      because downloads only ever add files. Variant-keyed because a
      page can render art crops and full cards of the same id with
      independent readiness (see netdecks).
    * `@card_image_requests` — every id requested this session, per
      variant. Internal bookkeeping for recomputes; templates should
      not read it.

  ## Mechanics

  `request/3` disk-checks only ids not already known cached, then
  downloads the rest off the LiveView process via `start_async`. A
  `:handle_async` lifecycle hook (installed once, on first request)
  re-runs the disk check when a download batch completes, so the
  changed assign flips placeholders to images. Async names are unique
  per request; overlapping batches each trigger a recompute over the
  full requested set, so late completions are never lost.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, start_async: 3]

  alias Scry2.Cards.ImageCache
  alias Scry2.Config

  @type variant :: :full | :art
  @type by_variant :: %{full: MapSet.t(), art: MapSet.t()}

  @variants [:full, :art]

  @doc """
  Declare that the page renders images for `arena_ids` and start
  downloading any that are missing. Idempotent and cheap when
  everything is already cached (one `File.exists?` per new id).
  """
  @spec request(Phoenix.LiveView.Socket.t(), [integer() | nil], keyword()) ::
          Phoenix.LiveView.Socket.t()
  def request(socket, arena_ids, opts \\ []) do
    variants = Keyword.get(opts, :variants, [:full])

    socket = init(socket)
    requests = merge_requests(socket.assigns.card_image_requests, arena_ids, variants)
    cached = refresh_cached(requests, socket.assigns.cached_card_ids)

    socket
    |> assign(:card_image_requests, requests)
    |> assign(:cached_card_ids, cached)
    |> download(missing(requests, cached))
  end

  @doc "The empty per-variant id map — initial value of both managed assigns."
  @spec empty() :: by_variant()
  def empty, do: Map.new(@variants, &{&1, MapSet.new()})

  @doc """
  Union `arena_ids` (nils dropped) into the given variants' request
  sets, leaving other variants untouched.
  """
  @spec merge_requests(by_variant(), [integer() | nil], [variant()]) :: by_variant()
  def merge_requests(requests, arena_ids, variants) do
    ids = arena_ids |> Enum.reject(&is_nil/1) |> MapSet.new()

    Enum.reduce(variants, requests, fn variant, requests ->
      Map.update!(requests, variant, &MapSet.union(&1, ids))
    end)
  end

  @doc """
  Disk-check every requested-but-not-yet-cached id and union the hits
  into `cached`. Never removes an id: cached files are only ever added,
  so the set is monotonic within a session.
  """
  @spec refresh_cached(by_variant(), by_variant(), String.t()) :: by_variant()
  def refresh_cached(requests, cached, cache_dir \\ Config.get(:image_cache_dir)) do
    Map.new(cached, fn {variant, cached_ids} ->
      on_disk =
        requests[variant]
        |> MapSet.difference(cached_ids)
        |> Enum.filter(&ImageCache.cached?(&1, variant, cache_dir))

      {variant, MapSet.union(cached_ids, MapSet.new(on_disk))}
    end)
  end

  @doc """
  Requested ids with no cached image yet, as sorted lists keyed by
  variant. Variants with nothing missing are omitted, so `%{}` means
  there is nothing to download.
  """
  @spec missing(by_variant(), by_variant()) :: %{optional(variant()) => [integer()]}
  def missing(requests, cached) do
    for {variant, requested_ids} <- requests,
        ids = requested_ids |> MapSet.difference(cached[variant]) |> Enum.sort(),
        ids != [],
        into: %{} do
      {variant, ids}
    end
  end

  # ── Socket wiring ────────────────────────────────────────────────────

  defp init(socket) do
    if Map.has_key?(socket.assigns, :card_image_requests) do
      socket
    else
      socket
      |> assign(:card_image_requests, empty())
      |> assign(:cached_card_ids, empty())
      |> attach_hook(:card_images, :handle_async, &on_download_complete/3)
    end
  end

  defp download(socket, missing_by_variant) when missing_by_variant == %{}, do: socket

  defp download(socket, missing_by_variant) do
    if connected?(socket) do
      name = {:card_images, System.unique_integer([:positive])}

      start_async(socket, name, fn ->
        Enum.each(missing_by_variant, fn {variant, ids} ->
          ImageCache.ensure_cached(ids, variant: variant)
        end)
      end)
    else
      socket
    end
  end

  defp on_download_complete({:card_images, _}, _result, socket) do
    cached = refresh_cached(socket.assigns.card_image_requests, socket.assigns.cached_card_ids)
    {:halt, assign(socket, :cached_card_ids, cached)}
  end

  defp on_download_complete(_name, _result, socket), do: {:cont, socket}
end
