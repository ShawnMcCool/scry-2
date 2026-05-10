defmodule Scry2.Showcase do
  @moduledoc """
  Public facade for the homepage composition layer.

  Reads from `Scry2.Insights` and (in activity-mode fallback) other
  domain context public APIs. Owns no tables — Showcase is stateless.
  Output is a list of `%Scry2.Showcase.TileSpec{}` values consumed by
  the web layer's universal `<.tile spec={...}>` component.

  ## Pipeline

      Insights.list_active(:home)  + activity-mode fallback candidates
        → Showcase.Homepage.tiles/1 (pattern mode | activity mode)
          → tile_types/* (one builder per tile shape)
            → [%TileSpec{}]

  ## Modularity

  Adding a tile type: create `Scry2.Showcase.TileTypes.<Name>` returning
  `%TileSpec{} | nil`, add it to `Showcase.Homepage`'s candidate pool,
  and write a test. No other changes needed — the Tile component
  pattern-matches on `spec.composition`.
  """

  alias Scry2.Showcase.{Homepage, TileSpec}

  @doc """
  Returns up to four tiles for the requested surface. `:home` is the
  only surface today; future surfaces (e.g. an insights browser sidebar)
  can be added by extending this function and adding a corresponding
  selector module.
  """
  @spec tiles_for(atom(), keyword()) :: [TileSpec.t()]
  def tiles_for(surface, opts \\ [])
  def tiles_for(:home, opts), do: Homepage.tiles(opts)
  def tiles_for(_, _), do: []
end
