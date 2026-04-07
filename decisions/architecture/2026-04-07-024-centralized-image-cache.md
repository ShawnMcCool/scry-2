---
status: accepted
date: 2026-04-07
---
# Centralized image cache with batch API

## Context and Problem Statement

Scry2's UI philosophy is "show don't hide" (UI-004) — card images are displayed inline everywhere: mulligan hands, deck lists, draft picks, card browsers. A single page can easily require 30+ card images (e.g., 5 mulligan rows with 7 cards each). Loading these as individual HTTP requests to Scryfall is both slow and disrespectful of their API.

Two problems need solving:
1. **Performance** — 33 individual image loads per page is too many round-trips.
2. **Caching** — the same card images appear across many pages; downloading them repeatedly wastes bandwidth and adds latency.

## Decision Outcome

Build a centralized image caching service (`Scry2.Cards.ImageCache`) that serves card images from a local directory, fetching from Scryfall on cache miss.

### Batch API

The primary interface is a batch request: the UI collects all `arena_id` values needed for a page render and requests them in a single call. The cache returns all available image data (paths or binary) in one response. This reduces per-page overhead from N individual loads to 1 batch lookup + M cache-miss downloads.

```elixir
# UI collects all card IDs needed for the page
arena_ids = [91001, 91002, 91003, ..., 91033]
images = ImageCache.get_batch(arena_ids)
# => %{91001 => "/path/to/91001.jpg", 91002 => "/path/to/91002.jpg", ...}
```

### Lazy download on cache miss

When the cache doesn't have an image, it downloads it from Scryfall using the `image_uris` stored in `cards_scryfall_cards` (populated by the Scryfall bulk import — ADR-024 depends on the independent Scryfall dataset). Downloaded images are stored locally and served from cache on subsequent requests.

### Local storage

Images are stored in a configurable directory (via `Scry2.Config`, e.g., `~/.local/share/scry_2/images/`). The directory structure is flat: `{arena_id}.jpg`. The entire cache directory can be deleted and rebuilt on demand — images are always re-downloadable from Scryfall.

### Centralization

The cache is centralized (single service, not per-LiveView) because:
- Card images are shared across all pages — one cache serves everyone
- Download concurrency and rate limiting need coordination
- Cache invalidation (if Scryfall updates art) happens in one place

### Consequences

* Good, because page loads are fast — most images served from local disk
* Good, because Scryfall API usage is minimal — each image downloaded at most once
* Good, because the batch API eliminates per-card round-trip overhead in the UI
* Good, because the cache is disposable — delete the directory and images re-download on demand
* Neutral, because first-time page loads for uncached cards will be slower while images download
* Neutral, because local disk usage grows with the card pool (~200KB per image, ~20k Arena cards = ~4GB max)
