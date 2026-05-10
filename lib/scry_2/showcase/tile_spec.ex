defmodule Scry2.Showcase.TileSpec do
  @moduledoc """
  The data shape consumed by the universal `<.tile spec={...}>` web
  component. A TileSpec is a fully-rendered description of a single
  homepage tile — title, body, art, stats, meta line, click target —
  produced by a `tile_types` module from raw domain data or an Insight.

  `:composition` selects which layout the Tile component dispatches to:

    * `:activity` — α tease (image hero, factual title, meta line)
    * `:insight`  — γ mini-page (kind, title, body, stats row)
  """

  @type composition :: :activity | :insight
  @type stat :: %{required(String.t()) => String.t()}
  @type t :: %__MODULE__{
          kind: atom(),
          composition: composition(),
          title: String.t(),
          body: String.t() | nil,
          art: map() | nil,
          stats: [stat()] | nil,
          meta: [String.t()],
          target: {:navigate, String.t()},
          badge: nil | :tier_2
        }

  @enforce_keys [:kind, :composition, :title, :target]

  defstruct kind: nil,
            composition: nil,
            title: nil,
            body: nil,
            art: nil,
            stats: nil,
            meta: [],
            target: nil,
            badge: nil
end
