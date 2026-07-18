defmodule Scry2Web.NavHelpers do
  @moduledoc """
  Pure helpers for the main navigation. Single source of truth for the
  nav item list (consumed by both the desktop inline nav and the
  hamburger overflow dropdown), plus tiny renderable hints derived from
  the `:nav_update` socket assign.
  """

  @items [
    %{path: "/matches", label: "Matches"},
    %{path: "/decks", label: "Decks"},
    %{path: "/drafts", label: "Drafts"},
    %{path: "/cards", label: "Cards"},
    %{path: "/player", label: "Player"},
    %{path: "/ranks", label: "Ranks"},
    %{path: "/economy", label: "Economy"},
    %{path: "/collection", label: "Collection"}
  ]

  @doc "Canonical ordered list of main-nav items."
  @spec items() :: [%{path: String.t(), label: String.t()}]
  def items, do: @items

  @doc """
  True when `current_path` is on or under `item_path`.

  Special-cases `"/"` so the home route does not light up every nav item
  via prefix match.
  """
  @spec active?(String.t() | nil, String.t()) :: boolean()
  def active?(nil, _), do: false
  def active?(_, "/"), do: false
  def active?(current, item_path), do: String.starts_with?(current, item_path)

  @doc """
  Distills the gear's `:nav_update` assign into a render hint.

  Returns `%{kind: :badge, label: "v0.X.Y"}` when an update is waiting
  so the gear can show the version inline; returns `%{kind: :none}`
  otherwise. Anything off the happy path (missing summary, unknown
  status) collapses to `:none` rather than crashing.
  """
  @spec gear_indicator(map()) :: %{kind: :badge | :none, label: String.t() | nil}
  def gear_indicator(%{summary: %{status: :update_available, version: version}})
      when is_binary(version) do
    %{kind: :badge, label: "v#{version}"}
  end

  def gear_indicator(_), do: %{kind: :none, label: nil}
end
