defmodule Scry2.Cards.ImageCache do
  @moduledoc """
  Centralized image cache for Scryfall card art (ADR-024).

  Downloads card images from Scryfall on first access and stores them
  in a configurable local directory. Subsequent requests are served
  directly from disk.

  ## Usage

  Call `ensure_cached/2` in LiveView mount with all arena_ids the page
  needs. This downloads any missing images. Then use
  `Scry2Web.CardComponents.card_image/1` in templates — it renders an
  `<img>` tag pointing to the Plug route that serves from the cache dir.

  ## Storage

  Images are stored as `{arena_id}.jpg` in a flat directory.
  Default: `~/.local/share/scry_2/images/` (configurable via
  `Scry2.Config` key `:image_cache_dir`).

  The entire directory can be deleted — images re-download on demand.

  ## Cache versioning

  A `cache-version` marker file records which display-art semantics the
  cached files were downloaded under. When the semantics change (e.g.
  v2: every image is the name's most basic printing, per
  `Scry2.Cards.BasicPrinting`), bumping `@cache_version` clears the
  directory and images re-download on demand — no manual step for
  installs carrying art from the old rules.

  The turnover is deferred until the read model actually carries
  stamped display art (`Cards.display_art_stamped?/0`): clearing before
  synthesis stamps would re-download literal printings through the API
  fallback and cache the wrong art under the new version. The check
  runs at the top of `ensure_cached/2` — the read path that depends on
  the semantics, in caller processes that always have DB access — so
  the clear fires exactly once, on the first image use after the new
  semantics are in force.

  ## Reported size

  The cache tracks its own file count and total bytes as it writes, and
  `usage/0` hands them out in constant time. `Scry2.Cards` reports them
  on the /cards Data Sources panel. See
  `Scry2.Cards.ImageCache.DiskUsage` for why the reader does not derive
  them from the directory.
  """

  use GenServer

  alias Scry2.Cards
  alias Scry2.Cards.ImageCache.DiskUsage
  alias Scry2.Config

  require Scry2.Log, as: Log

  @empty_stats %{cached: 0, downloaded: 0, failed: 0}

  @scryfall_headers [
    {"user-agent", "Scry2/0.1.0 (personal project; no bulk scraping)"},
    {"accept", "application/json, image/*"}
  ]

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # v2: images are the canonical basic printing's art (BasicPrinting),
  # not the arena_id's literal printing.
  @cache_version "2"

  @doc "The display-art semantics version the cache dir must match."
  @spec cache_version() :: String.t()
  def cache_version, do: @cache_version

  @doc """
  Ensures the cache dir holds images downloaded under the current
  display-art semantics: on a version mismatch (or an unversioned dir),
  deletes every cached image and stamps the current version. Images
  re-download on demand.
  """
  @spec ensure_version!(String.t()) :: :ok
  def ensure_version!(cache_dir) do
    File.mkdir_p!(cache_dir)
    marker = Path.join(cache_dir, "cache-version")

    if File.read(marker) != {:ok, @cache_version} do
      stale = DiskUsage.image_files(cache_dir)
      # Non-bang rm: concurrent ensure_cached callers may race the clear.
      Enum.each(stale, &File.rm/1)

      if stale != [] do
        Log.info(:importer, "image cache: cleared #{length(stale)} images for v#{@cache_version}")
      end

      File.write!(marker, @cache_version)
      GenServer.cast(__MODULE__, {:cleared, cache_dir})
    end

    :ok
  end

  # Runs the version turnover only once the read model carries stamped
  # display art — see "Cache versioning" in the moduledoc. The marker
  # read keeps the steady-state cost to one file read per call.
  defp maybe_turn_over_cache(cache_dir) do
    marker = Path.join(cache_dir, "cache-version")

    if File.read(marker) != {:ok, @cache_version} and Cards.display_art_stamped?() do
      ensure_version!(cache_dir)
    end

    :ok
  end

  @spec url_for(integer(), :full | :art) :: String.t()
  def url_for(arena_id, variant \\ :full) when is_integer(arena_id) do
    "/images/cards/#{arena_id}#{suffix(variant)}.jpg"
  end

  @doc """
  The cache's current file count and total bytes on disk.

  Read from the running total the cache maintains as it writes — see
  `Scry2.Cards.ImageCache.DiskUsage`. Constant time regardless of how
  many images are cached.
  """
  @spec usage() :: %{count: non_neg_integer(), bytes: non_neg_integer()}
  def usage, do: GenServer.call(__MODULE__, :usage)

  @doc "Returns true if the image for this arena_id is cached on disk."
  @spec cached?(integer(), :full | :art, String.t()) :: boolean()
  def cached?(arena_id, variant \\ :full, cache_dir \\ Config.get(:image_cache_dir)) do
    arena_id |> path_for(variant, cache_dir) |> File.exists?()
  end

  @spec path_for(integer(), :full | :art, String.t()) :: String.t()
  def path_for(arena_id, variant \\ :full, cache_dir \\ Config.get(:image_cache_dir)) do
    Path.join(cache_dir, "#{arena_id}#{suffix(variant)}.jpg")
  end

  defp suffix(:art), do: "-art"
  defp suffix(_), do: ""

  @spec ensure_cached([integer()], keyword()) ::
          {:ok,
           %{cached: non_neg_integer(), downloaded: non_neg_integer(), failed: non_neg_integer()}}
  def ensure_cached(arena_ids, opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, Config.get(:image_cache_dir))
    req_options = Keyword.get(opts, :req_options, [])
    variant = Keyword.get(opts, :variant, :full)

    File.mkdir_p!(cache_dir)
    maybe_turn_over_cache(cache_dir)

    {stats, downloaded_bytes} =
      Enum.reduce(arena_ids, {@empty_stats, 0}, fn arena_id, {stats, bytes} ->
        path = path_for(arena_id, variant, cache_dir)

        if File.exists?(path) do
          {%{stats | cached: stats.cached + 1}, bytes}
        else
          case download_image(arena_id, path, variant, req_options) do
            {:ok, size} -> {%{stats | downloaded: stats.downloaded + 1}, bytes + size}
            :error -> {%{stats | failed: stats.failed + 1}, bytes}
          end
        end
      end)

    if stats.downloaded > 0 do
      GenServer.cast(__MODULE__, {:downloaded, cache_dir, stats.downloaded, downloaded_bytes})
      Log.info(:importer, "image cache: downloaded #{stats.downloaded} #{variant} card images")
    end

    {:ok, stats}
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  # The startup scan is the one authoritative measurement of the cache
  # directory; `handle_continue` runs it before any other message, so a
  # `usage/0` call can never observe a half-built total. It is deferred out
  # of `init/1` so a large cache does not hold up the supervision tree.
  @impl true
  def init(_opts) do
    cache_dir = Config.get(:image_cache_dir)
    File.mkdir_p!(cache_dir)
    {:ok, DiskUsage.empty(cache_dir), {:continue, :scan}}
  end

  @impl true
  def handle_continue(:scan, usage), do: {:noreply, DiskUsage.scan(usage.dir)}

  @impl true
  def handle_call(:usage, _from, usage) do
    {:reply, %{count: usage.count, bytes: usage.bytes}, usage}
  end

  @impl true
  def handle_cast({:downloaded, cache_dir, count, bytes}, usage) do
    {:noreply, DiskUsage.add(usage, cache_dir, count, bytes)}
  end

  def handle_cast({:cleared, cache_dir}, usage) do
    {:noreply, DiskUsage.reset(usage, cache_dir)}
  end

  # ── Internals ───────────────────────────────────────────────────────────

  @typep download :: {:ok, non_neg_integer()} | :error

  @spec download_image(integer(), String.t(), :full | :art, keyword()) :: download()
  defp download_image(arena_id, path, :art, req_options) do
    case Cards.get_art_url_for_arena_id(arena_id) do
      nil -> :error
      url -> fetch_and_save(url, path, req_options)
    end
  end

  defp download_image(arena_id, path, :full, req_options) do
    case Cards.get_image_url_for_arena_id(arena_id) do
      nil ->
        download_image_via_api(arena_id, path, req_options)

      image_url ->
        fetch_and_save(image_url, path, req_options)
    end
  end

  defp download_image_via_api(arena_id, path, req_options) do
    case Cards.get_mtga_card(arena_id) do
      nil ->
        :error

      %{expansion_code: code, collector_number: num}
      when code in [nil, ""] or num in [nil, ""] ->
        :error

      %{expansion_code: code, collector_number: num} ->
        case fetch_scryfall_image_url(code, num, req_options) do
          {:ok, url} -> fetch_and_save(url, path, req_options)
          :error -> :error
        end
    end
  end

  defp fetch_scryfall_image_url(set_code, collector_number, req_options) do
    url = "https://api.scryfall.com/cards/#{String.downcase(set_code)}/#{collector_number}"

    options =
      Keyword.merge(
        [url: url, receive_timeout: 10_000, headers: @scryfall_headers],
        req_options
      )

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: %{"image_uris" => %{"normal" => image_url}}}} ->
        {:ok, image_url}

      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        # DFC cards: try card_faces[0].image_uris
        case get_in(body, ["card_faces", Access.at(0), "image_uris", "normal"]) do
          nil -> :error
          image_url -> {:ok, image_url}
        end

      _ ->
        :error
    end
  end

  defp fetch_and_save(url, path, req_options) do
    options =
      Keyword.merge(
        [url: url, receive_timeout: 15_000, headers: @scryfall_headers],
        req_options
      )

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        File.write!(path, body)
        {:ok, byte_size(body)}

      {:ok, %Req.Response{status: status}} ->
        Log.warning(
          :importer,
          "image cache: HTTP #{status} for arena_id #{Path.basename(path, ".jpg")}"
        )

        :error

      {:error, reason} ->
        Log.warning(
          :importer,
          "image cache: download failed for #{Path.basename(path, ".jpg")}: #{inspect(reason)}"
        )

        :error
    end
  end
end
