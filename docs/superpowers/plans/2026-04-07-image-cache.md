# Image Cache & Card Components — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a centralized image cache that downloads Scryfall card images to local disk, serves them via a Plug route with immutable browser caching, and provides reusable LiveView components for displaying card images.

**Architecture:** `Scry2.Cards.ImageCache` GenServer manages a local directory of card images, downloading from Scryfall on cache miss. `Scry2Web.Plugs.CardImage` serves cached images with `Cache-Control: immutable`. `Scry2Web.CardComponents` provides `card_image/1` and `card_hand/1` function components for LiveViews.

**Tech Stack:** Elixir/Phoenix, Req (HTTP), Plug, Phoenix.Component

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/scry_2/config.ex` | Modify | Add `:image_cache_dir` config key |
| `defaults/scry_2.toml` | Modify | Add `[images]` section with `cache_dir` |
| `lib/scry_2/cards/image_cache.ex` | Create | GenServer — ensure_cached, downloads, path management |
| `lib/scry_2/application.ex` | Modify | Add ImageCache to supervision tree |
| `lib/scry_2_web/plugs/card_image.ex` | Create | Plug — serve images from cache dir with immutable headers |
| `lib/scry_2_web/router.ex` | Modify | Add `/images/cards/:arena_id` route |
| `lib/scry_2_web/components/card_components.ex` | Create | Function components — card_image, card_hand |
| `test/scry_2/cards/image_cache_test.exs` | Create | Cache logic + download tests |
| `test/scry_2_web/plugs/card_image_test.exs` | Create | Plug serving + header tests |

---

### Task 1: Config — add `:image_cache_dir`

**Files:**
- Modify: `lib/scry_2/config.ex`
- Modify: `defaults/scry_2.toml`

- [ ] **Step 1: Add config key to `lib/scry_2/config.ex`**

In the `@type key` union (line 13), add `| :image_cache_dir` after `:cards_scryfall_bulk_url`.

In `load_config/0` defaults map (line 41), add:

```elixir
image_cache_dir: Path.expand("~/.local/share/scry_2/images/"),
```

In `merge_toml/2` (line 79), add:

```elixir
image_cache_dir:
  expand(get_in(toml, ["images", "cache_dir"])) || defaults.image_cache_dir,
```

- [ ] **Step 2: Add TOML documentation to `defaults/scry_2.toml`**

Add at the end, before `[workers]`:

```toml
# ── Card images ──────────────────────────────────────────────────────────
[images]
# Directory to cache downloaded card images locally. Scryfall card art is
# fetched on first access and stored here permanently. The directory can
# be deleted — images re-download on demand.
cache_dir = "~/.local/share/scry_2/images/"
```

- [ ] **Step 3: Verify compilation**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warnings-as-errors
```

Expected: zero warnings.

---

### Task 2: ImageCache GenServer — core logic + tests

**Files:**
- Create: `lib/scry_2/cards/image_cache.ex`
- Create: `test/scry_2/cards/image_cache_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/scry_2/cards/image_cache_test.exs`:

```elixir
defmodule Scry2.Cards.ImageCacheTest do
  use Scry2.DataCase, async: true

  alias Scry2.Cards.ImageCache
  alias Scry2.TestFactory

  @image_url "https://cards.scryfall.io/normal/front/test.jpg"

  setup do
    # Use a unique temp dir per test to avoid cross-contamination.
    cache_dir = Path.join(System.tmp_dir!(), "scry2_test_images_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cache_dir)

    on_exit(fn -> File.rm_rf!(cache_dir) end)

    %{cache_dir: cache_dir}
  end

  describe "url_for/1" do
    test "returns the URL path for an arena_id" do
      assert ImageCache.url_for(91001) == "/images/cards/91001.jpg"
    end
  end

  describe "path_for/2" do
    test "returns the filesystem path for an arena_id", %{cache_dir: cache_dir} do
      path = ImageCache.path_for(91001, cache_dir)
      assert path == Path.join(cache_dir, "91001.jpg")
    end
  end

  describe "ensure_cached/2" do
    test "returns immediately for empty list", %{cache_dir: cache_dir} do
      assert {:ok, %{cached: 0, downloaded: 0, failed: 0}} =
               ImageCache.ensure_cached([], cache_dir: cache_dir)
    end

    test "reports already-cached files", %{cache_dir: cache_dir} do
      # Pre-create a cached image file.
      File.write!(Path.join(cache_dir, "91001.jpg"), "fake jpeg")

      assert {:ok, %{cached: 1, downloaded: 0, failed: 0}} =
               ImageCache.ensure_cached([91001], cache_dir: cache_dir)
    end

    test "downloads missing images from Scryfall", %{cache_dir: cache_dir} do
      # Seed a ScryfallCard with image_uris.
      TestFactory.create_scryfall_card(%{
        arena_id: 91_002,
        name: "Test Card",
        image_uris: %{"normal" => @image_url}
      })

      Req.Test.stub(ImageCache, fn conn ->
        Plug.Conn.resp(conn, 200, "fake jpeg data")
      end)

      assert {:ok, %{cached: 0, downloaded: 1, failed: 0}} =
               ImageCache.ensure_cached([91_002],
                 cache_dir: cache_dir,
                 req_options: [plug: {Req.Test, ImageCache}]
               )

      assert File.exists?(Path.join(cache_dir, "91002.jpg"))
    end

    test "skips arena_ids with no ScryfallCard record", %{cache_dir: cache_dir} do
      assert {:ok, %{cached: 0, downloaded: 0, failed: 1}} =
               ImageCache.ensure_cached([99_999_999], cache_dir: cache_dir)
    end

    test "skips cards with no image_uris", %{cache_dir: cache_dir} do
      TestFactory.create_scryfall_card(%{
        arena_id: 91_003,
        name: "No Image",
        image_uris: nil
      })

      assert {:ok, %{cached: 0, downloaded: 0, failed: 1}} =
               ImageCache.ensure_cached([91_003], cache_dir: cache_dir)
    end

    test "handles mixed cached and uncached", %{cache_dir: cache_dir} do
      File.write!(Path.join(cache_dir, "91001.jpg"), "fake jpeg")

      TestFactory.create_scryfall_card(%{
        arena_id: 91_004,
        name: "New Card",
        image_uris: %{"normal" => @image_url}
      })

      Req.Test.stub(ImageCache, fn conn ->
        Plug.Conn.resp(conn, 200, "downloaded jpeg")
      end)

      assert {:ok, %{cached: 1, downloaded: 1, failed: 0}} =
               ImageCache.ensure_cached([91_001, 91_004],
                 cache_dir: cache_dir,
                 req_options: [plug: {Req.Test, ImageCache}]
               )
    end
  end
end
```

- [ ] **Step 2: Run tests to verify RED**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/cards/image_cache_test.exs
```

Expected: all fail with `UndefinedFunctionError` — module doesn't exist yet.

- [ ] **Step 3: Implement ImageCache**

Create `lib/scry_2/cards/image_cache.ex`:

```elixir
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
  """

  use GenServer

  alias Scry2.Cards
  alias Scry2.Config

  require Scry2.Log, as: Log

  @scryfall_headers [
    {"user-agent", "Scry2/0.1.0 (personal project; no bulk scraping)"},
    {"accept", "image/*"}
  ]

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the URL path for a cached card image.

  Pure function — no disk check, no download.
  """
  @spec url_for(integer()) :: String.t()
  def url_for(arena_id) when is_integer(arena_id) do
    "/images/cards/#{arena_id}.jpg"
  end

  @doc """
  Returns the filesystem path for a cached card image.
  """
  @spec path_for(integer(), String.t()) :: String.t()
  def path_for(arena_id, cache_dir \\ Config.get(:image_cache_dir)) do
    Path.join(cache_dir, "#{arena_id}.jpg")
  end

  @doc """
  Ensures all given arena_ids have images cached on disk.

  Checks which files already exist, downloads any missing from Scryfall
  using `image_uris` from `cards_scryfall_cards`.

  Options:
    * `:cache_dir` — override the configured cache directory (for tests)
    * `:req_options` — extra Req options (for test stubs)

  Returns `{:ok, %{cached: n, downloaded: n, failed: n}}`.
  """
  @spec ensure_cached([integer()], keyword()) ::
          {:ok, %{cached: non_neg_integer(), downloaded: non_neg_integer(), failed: non_neg_integer()}}
  def ensure_cached(arena_ids, opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, Config.get(:image_cache_dir))
    req_options = Keyword.get(opts, :req_options, [])

    File.mkdir_p!(cache_dir)

    stats =
      Enum.reduce(arena_ids, %{cached: 0, downloaded: 0, failed: 0}, fn arena_id, stats ->
        path = path_for(arena_id, cache_dir)

        if File.exists?(path) do
          %{stats | cached: stats.cached + 1}
        else
          case download_image(arena_id, path, req_options) do
            :ok -> %{stats | downloaded: stats.downloaded + 1}
            :error -> %{stats | failed: stats.failed + 1}
          end
        end
      end)

    if stats.downloaded > 0 do
      Log.info(:importer, "image cache: downloaded #{stats.downloaded} card images")
    end

    {:ok, stats}
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    cache_dir = Config.get(:image_cache_dir)
    File.mkdir_p!(cache_dir)
    {:ok, %{cache_dir: cache_dir}}
  end

  # ── Internals ───────────────────────────────────────────────────────────

  defp download_image(arena_id, path, req_options) do
    case Cards.get_scryfall_by_arena_id(arena_id) do
      nil ->
        :error

      %{image_uris: nil} ->
        :error

      %{image_uris: image_uris} ->
        case image_uris["normal"] do
          nil ->
            :error

          url ->
            fetch_and_save(url, path, req_options)
        end
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
        # Scryfall asks for 50-100ms between requests.
        Process.sleep(100)
        :ok

      {:ok, %Req.Response{status: status}} ->
        Log.warning(:importer, "image cache: HTTP #{status} for arena_id #{Path.basename(path, ".jpg")}")
        :error

      {:error, reason} ->
        Log.warning(:importer, "image cache: download failed for #{Path.basename(path, ".jpg")}: #{inspect(reason)}")
        :error
    end
  end
end
```

- [ ] **Step 4: Run tests to verify GREEN**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/cards/image_cache_test.exs
```

Expected: all pass.

- [ ] **Step 5: Run full test suite**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test
```

Expected: all pass, zero warnings.

---

### Task 3: Add ImageCache to supervision tree

**Files:**
- Modify: `lib/scry_2/application.ex`

- [ ] **Step 1: Add ImageCache to children list**

In `lib/scry_2/application.ex`, add `Scry2.Cards.ImageCache` after `Scry2.Console.RecentEntries` and before `{Oban, ...}`:

```elixir
        Scry2.Console.RecentEntries,
        # Card image cache — ensures cache directory exists on startup.
        Scry2.Cards.ImageCache,
        {Oban, Application.fetch_env!(:scry_2, Oban)},
```

- [ ] **Step 2: Verify application starts**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warnings-as-errors
```

Expected: zero warnings.

---

### Task 4: CardImage Plug — serve images with caching headers

**Files:**
- Create: `lib/scry_2_web/plugs/card_image.ex`
- Create: `test/scry_2_web/plugs/card_image_test.exs`
- Modify: `lib/scry_2_web/router.ex`

- [ ] **Step 1: Write failing tests**

Create `test/scry_2_web/plugs/card_image_test.exs`:

```elixir
defmodule Scry2Web.Plugs.CardImageTest do
  use Scry2.ConnCase, async: true

  alias Scry2.Cards.ImageCache

  setup do
    cache_dir = Path.join(System.tmp_dir!(), "scry2_plug_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cache_dir)

    # Write a fake image file.
    File.write!(Path.join(cache_dir, "91001.jpg"), "fake jpeg data")

    on_exit(fn -> File.rm_rf!(cache_dir) end)

    %{cache_dir: cache_dir}
  end

  describe "GET /images/cards/:arena_id.jpg" do
    test "serves a cached image with correct headers", %{conn: conn, cache_dir: cache_dir} do
      conn =
        conn
        |> assign(:image_cache_dir, cache_dir)
        |> get("/images/cards/91001.jpg")

      assert conn.status == 200
      assert conn.resp_body == "fake jpeg data"
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    test "returns 404 for missing image", %{conn: conn, cache_dir: cache_dir} do
      conn =
        conn
        |> assign(:image_cache_dir, cache_dir)
        |> get("/images/cards/99999.jpg")

      assert conn.status == 404
    end
  end
end
```

- [ ] **Step 2: Run tests to verify RED**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/plugs/card_image_test.exs
```

Expected: failures — route doesn't exist yet.

- [ ] **Step 3: Implement the Plug**

Create `lib/scry_2_web/plugs/card_image.ex`:

```elixir
defmodule Scry2Web.Plugs.CardImage do
  @moduledoc """
  Serves cached card images from the image cache directory.

  Returns the image with `Cache-Control: immutable` so the browser
  never re-requests it. Card art doesn't change.

  Mounted at `GET /images/cards/:arena_id.jpg` in the router.
  """

  import Plug.Conn

  alias Scry2.Cards.ImageCache
  alias Scry2.Config

  def init(opts), do: opts

  def call(%Plug.Conn{path_params: %{"arena_id" => arena_id_str}} = conn, _opts) do
    cache_dir = conn.assigns[:image_cache_dir] || Config.get(:image_cache_dir)

    with {arena_id, ""} <- Integer.parse(arena_id_str),
         path <- ImageCache.path_for(arena_id, cache_dir),
         true <- File.exists?(path) do
      conn
      |> put_resp_content_type("image/jpeg")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_file(200, path)
    else
      _ ->
        conn
        |> send_resp(404, "Not found")
    end
  end
end
```

- [ ] **Step 4: Add route to `lib/scry_2_web/router.ex`**

Add above the `scope "/", Scry2Web do` block:

```elixir
  # Card image cache — served from disk with immutable browser caching.
  # Outside the :browser pipeline (no CSRF, no session — just a static file).
  get "/images/cards/:arena_id.jpg", Scry2Web.Plugs.CardImage, :call
```

Note: This must be placed BEFORE the `scope "/", Scry2Web do` block so it matches first. Phoenix routes match in order.

- [ ] **Step 5: Run tests to verify GREEN**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/plugs/card_image_test.exs
```

Expected: all pass.

Note: The test uses `conn |> assign(:image_cache_dir, cache_dir)` to override the cache directory. The Plug reads from `conn.assigns[:image_cache_dir]` first, falling back to `Config.get(:image_cache_dir)`. This makes the Plug testable without touching global config. If the test framework doesn't route through the Plug automatically (because the route expects `.jpg` suffix), the test may need to call the Plug directly:

```elixir
conn =
  conn
  |> assign(:image_cache_dir, cache_dir)
  |> Map.put(:path_params, %{"arena_id" => "91001"})
  |> Scry2Web.Plugs.CardImage.call([])
```

Adjust the test approach based on what works with the project's test setup.

---

### Task 5: CardComponents — reusable image display components

**Files:**
- Create: `lib/scry_2_web/components/card_components.ex`

- [ ] **Step 1: Create the component module**

```elixir
defmodule Scry2Web.CardComponents do
  @moduledoc """
  Reusable function components for displaying card images.

  These components render `<img>` tags pointing to the card image
  Plug route (`/images/cards/{arena_id}.jpg`). Call
  `Scry2.Cards.ImageCache.ensure_cached/2` in your LiveView mount
  before rendering — this ensures images are on disk before the
  browser requests them.

  ## Usage

      # In mount:
      ImageCache.ensure_cached(arena_ids)

      # In template:
      <.card_image arena_id={91001} name="Lightning Bolt" />
      <.card_hand arena_ids={[91001, 91002, 91003]} />
  """

  use Phoenix.Component

  alias Scry2.Cards.ImageCache

  @doc """
  Renders a single card image.

  ## Examples

      <.card_image arena_id={91001} />
      <.card_image arena_id={91001} name="Lightning Bolt" class="w-24" />
  """
  attr :arena_id, :integer, required: true
  attr :name, :string, default: "Card image"
  attr :class, :string, default: "w-20"

  def card_image(assigns) do
    assigns = assign(assigns, :src, ImageCache.url_for(assigns.arena_id))

    ~H"""
    <img src={@src} alt={@name} loading="lazy" class={@class} />
    """
  end

  @doc """
  Renders a horizontal row of card images.

  Used for mulligan hands, opening hands, deck displays — any
  context where multiple cards are shown inline.

  ## Examples

      <.card_hand arena_ids={[91001, 91002, 91003]} />
      <.card_hand arena_ids={hand} card_names={%{91001 => "Bolt"}} class="w-16" />
  """
  attr :arena_ids, :list, required: true
  attr :card_names, :map, default: %{}
  attr :class, :string, default: "w-20"

  def card_hand(assigns) do
    ~H"""
    <div class="flex gap-1 items-start">
      <.card_image
        :for={arena_id <- @arena_ids}
        arena_id={arena_id}
        name={Map.get(@card_names, arena_id, "Card image")}
        class={@class}
      />
    </div>
    """
  end
end
```

- [ ] **Step 2: Import in `lib/scry_2_web.ex`**

In the `html_helpers/0` function (which is imported by all LiveViews and components), add:

```elixir
import Scry2Web.CardComponents
```

This makes `card_image/1` and `card_hand/1` available in all templates without explicit import.

- [ ] **Step 3: Verify compilation**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warnings-as-errors
```

Expected: zero warnings.

---

### Task 6: Final verification

- [ ] **Step 1: Run full precommit**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit
```

Expected: zero warnings, all tests pass.

- [ ] **Step 2: Manual smoke test via tidewave**

```elixir
# Ensure some images are cached:
Scry2.Cards.ImageCache.ensure_cached([91001, 91002, 91003])

# Verify files on disk:
dir = Scry2.Config.get(:image_cache_dir)
File.ls!(dir) |> Enum.take(5)

# Verify URL helper:
Scry2.Cards.ImageCache.url_for(91001)
# => "/images/cards/91001.jpg"
```

Then open `http://localhost:4002/images/cards/91001.jpg` in a browser — should display a card image with correct caching headers.
