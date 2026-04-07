# Image Cache & Card Image Components — Design Spec

## Problem

Scry2's UI philosophy is "show don't hide" (UI-004) — card images are displayed inline everywhere. A single page can need 30+ card images. Without local caching, every image would be fetched from Scryfall on every page load. Without browser caching, navigating between pages re-downloads the same images.

## Solution

Three units working together:

### 1. `Scry2.Cards.ImageCache` (GenServer)

Manages a local directory of card images. Downloads from Scryfall on cache miss.

**Public API:**

- `ensure_cached([arena_id])` — checks which images exist on disk, downloads any missing from Scryfall. Returns `{:ok, %{cached: n, downloaded: n, failed: n}}`. Called in LiveView mount before rendering.
- `url_for(arena_id)` — returns the URL path `/images/cards/{arena_id}.jpg`. Pure function, no disk check.

**Download behavior:**

- Looks up `image_uris` on the `ScryfallCard` record for the given `arena_id`.
- Downloads the `"normal"` size (488×680px, ~50-100KB). Good balance of quality and size for inline display.
- Stores as `{arena_id}.jpg` in the cache directory.
- Downloads sequentially within a batch with a small delay between requests (Scryfall asks for 50-100ms between requests).
- Logs via `:importer` component: count of downloads, any failures.

**Supervision:**

- Added to the supervision tree in `application.ex` after `Scry2.Repo`.
- On init, ensures the cache directory exists (`File.mkdir_p!/1`).

**Config:**

- New key `:image_cache_dir` in `Scry2.Config`.
- Default: `~/.local/share/scry_2/images/`.
- TOML: `[images] cache_dir = "~/.local/share/scry_2/images/"`.
- Documented in `defaults/scry_2.toml`.

### 2. `Scry2Web.Plugs.CardImage` (Plug)

Serves cached card images over HTTP.

**Route:** `GET /images/cards/:arena_id.jpg`

**Behavior:**

- Reads the file from the image cache directory.
- Sets `Content-Type: image/jpeg`.
- Sets `Cache-Control: public, max-age=31536000, immutable` — browser caches forever. Card art doesn't change.
- Returns 404 if file doesn't exist on disk.

**Registered in:** `router.ex` as a pipeline-free route above the LiveView routes.

**Why a Plug, not static serving:** The cache directory is runtime-configurable and lives outside `priv/static`. Releases compile static assets into the binary — a Plug reads from the filesystem at runtime.

### 3. `Scry2Web.CardComponents` (Function Components)

Reusable Phoenix function components for displaying card images.

**`card_image/1`**

```elixir
attr :arena_id, :integer, required: true
attr :name, :string, default: nil  # alt text
attr :class, :string, default: ""
```

Renders: `<img src="/images/cards/{arena_id}.jpg" alt={name} loading="lazy" class={class} />`

Uses `ImageCache.url_for/1` for the src.

**`card_hand/1`**

```elixir
attr :arena_ids, :list, required: true
attr :card_names, :map, default: %{}  # optional %{arena_id => name} for alt text
attr :class, :string, default: ""
```

Renders a horizontal row of `card_image` components. Used for mulligan hands, opening hands, deck displays.

## LiveView Integration Pattern

```elixir
def mount(_params, _session, socket) do
  # ... load mulligan data ...
  arena_ids = extract_all_arena_ids(mulligans)
  ImageCache.ensure_cached(arena_ids)
  {:ok, assign(socket, mulligans: mulligans)}
end
```

```heex
<.card_hand arena_ids={mulligan.hand_arena_ids} />
```

**First visit:** `ensure_cached` downloads missing images. Browser fetches from our Plug. Plug serves from disk with immutable headers.

**Subsequent visits:** `ensure_cached` is a no-op (all on disk). Browser serves from its own HTTP cache. Zero network requests for images.

**Navigation:** Cards seen on previous pages are already in the browser cache. Only new cards trigger Plug requests.

## Decision Record

This implements ADR-024 (centralized image cache).

## Files

| File | Action | Purpose |
|------|--------|---------|
| `lib/scry_2/cards/image_cache.ex` | Create | GenServer — download, cache, serve paths |
| `lib/scry_2_web/plugs/card_image.ex` | Create | Plug — serve images from cache dir |
| `lib/scry_2_web/components/card_components.ex` | Create | Function components — card_image, card_hand |
| `lib/scry_2/config.ex` | Modify | Add `:image_cache_dir` key |
| `defaults/scry_2.toml` | Modify | Add `[images]` section |
| `lib/scry_2/application.ex` | Modify | Add ImageCache to supervision tree |
| `lib/scry_2_web/router.ex` | Modify | Add card image route |
| `test/scry_2/cards/image_cache_test.exs` | Create | Cache + download tests |
| `test/scry_2_web/plugs/card_image_test.exs` | Create | Plug serving tests |
