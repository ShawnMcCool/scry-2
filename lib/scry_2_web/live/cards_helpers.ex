defmodule Scry2Web.CardsHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.CardsLive`. Extracted per ADR-013.
  """

  alias Scry2.Cards.Card

  @doc "Renders the set code for a card, or `—` when no set is loaded."
  @spec set_code(Card.t()) :: String.t()
  def set_code(%Card{set: %{code: code}}) when is_binary(code), do: code
  def set_code(_), do: "—"

  @doc "Returns a daisyUI badge color class for the given rarity."
  @spec rarity_class(String.t() | nil) :: String.t()
  def rarity_class("mythic"), do: "badge-warning"
  def rarity_class("rare"), do: "badge-accent"
  def rarity_class("uncommon"), do: "badge-info"
  def rarity_class("common"), do: "badge-ghost"
  def rarity_class(_), do: "badge-ghost"

  @doc """
  Renders a short human label for a color identity string. An empty
  string or nil renders as "Colorless".
  """
  @spec color_identity_label(String.t() | nil) :: String.t()
  def color_identity_label(nil), do: "Colorless"
  def color_identity_label(""), do: "Colorless"
  def color_identity_label(identity) when is_binary(identity), do: identity

  @doc """
  Coerces raw URL params (always strings) into a filter map suitable for
  `Scry2.Cards.list_cards/1`. Empty strings become nil so the context
  skips the corresponding WHERE clause.
  """
  @spec coerce_filters(map()) :: map()
  def coerce_filters(params) when is_map(params) do
    %{
      name_like: blank_to_nil(params["name_like"]),
      rarity: blank_to_nil(params["rarity"]),
      set_code: blank_to_nil(params["set_code"])
    }
  end

  @doc """
  Turns user-submitted filter form params into a compact query string
  map suitable for `push_patch/2`. Drops empty values so the URL stays
  tidy.
  """
  @spec filter_params_to_query(map()) :: map()
  def filter_params_to_query(filter_params) when is_map(filter_params) do
    filter_params
    |> Map.new(fn {k, v} -> {k, v} end)
    |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
end
