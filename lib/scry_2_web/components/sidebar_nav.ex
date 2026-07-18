defmodule Scry2Web.SidebarNav do
  @moduledoc """
  Pure helpers for the left-rail navigation. Single source of truth for
  the sidebar item list — consumed by both the expanded and collapsed
  rail renderers.

  Two top-level sections, neither labelled:

    1. **General tools** (Cards) — reference data, not tied to the player.
    2. **Your data** — match history, decks, drafts, profile, economy,
       collection. Sub-grouped (Play / Profile / Economy / Collection)
       so the 8 items don't read as a flat dense list.

  A `nil` section label is the signal to render the separator above
  that section's content (used to divide "general tools" from
  "your data").
  """

  @type item :: %{path: String.t(), label: String.t(), icon: String.t()}
  @type section :: %{label: String.t() | nil, items: [item()]}

  @sections [
    %{
      label: nil,
      items: [
        %{path: "/cards", label: "Cards", icon: "hero-magnifying-glass"}
      ]
    },
    %{
      label: "Play",
      items: [
        %{path: "/matches", label: "Matches", icon: "hero-trophy"},
        %{path: "/decks", label: "Decks", icon: "hero-rectangle-stack"},
        %{path: "/netdecks", label: "NetDecks", icon: "hero-globe-alt"},
        %{path: "/drafts", label: "Drafts", icon: "hero-gift"}
      ]
    },
    %{
      label: "Profile",
      items: [
        %{path: "/player", label: "Player", icon: "hero-user"},
        %{path: "/ranks", label: "Ranks", icon: "hero-chart-bar-square"}
      ]
    },
    %{
      label: "Economy",
      items: [
        %{path: "/economy", label: "Economy", icon: "hero-banknotes"}
      ]
    },
    %{
      label: "Collection",
      items: [
        %{path: "/collection", label: "Collection", icon: "hero-archive-box"}
      ]
    }
  ]

  @doc "Canonical ordered list of sidebar sections."
  @spec sections() :: [section()]
  def sections, do: @sections

  @doc "Flat list of every nav item across every section."
  @spec items() :: [item()]
  def items do
    Enum.flat_map(@sections, & &1.items)
  end

  @doc """
  True when `current_path` is on or under `item_path`.

  Special-cases `"/"` so the home route does not light up every nav item
  via prefix match.
  """
  @spec active?(String.t() | nil, String.t()) :: boolean()
  def active?(nil, _), do: false
  def active?(_, "/"), do: false
  def active?(current, item_path), do: String.starts_with?(current, item_path)
end
