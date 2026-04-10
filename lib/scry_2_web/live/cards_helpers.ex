defmodule Scry2Web.CardsHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.CardsLive`. Extracted per ADR-013.
  """

  @doc "Returns true if any search text or filter is active."
  @spec any_filter_active?(String.t(), MapSet.t(), MapSet.t(), MapSet.t(), MapSet.t()) ::
          boolean()
  def any_filter_active?(search, colors, rarities, mana_values, types) do
    search != "" or
      not MapSet.equal?(colors, MapSet.new()) or
      not MapSet.equal?(rarities, MapSet.new()) or
      not MapSet.equal?(mana_values, MapSet.new()) or
      not MapSet.equal?(types, MapSet.new())
  end

  @doc "Converts an empty string to nil; passes through non-empty strings."
  @spec blank_to_nil(String.t() | nil) :: String.t() | nil
  def blank_to_nil(nil), do: nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(value) when is_binary(value), do: value

  @doc """
  Converts a `MapSet` of rarity strings to a filter value for `list_cards/1`.
  Returns nil for empty set (no rarity filter), a single string for one rarity,
  or a list for multiple.
  """
  @spec rarity_filter(MapSet.t()) :: nil | String.t() | [String.t()]
  def rarity_filter(rarities) do
    case MapSet.to_list(rarities) do
      [] -> nil
      [single] -> single
      list -> list
    end
  end

  @doc """
  Parses a mana value string from the UI toggle ("0"–"6" or "seven_plus")
  into the atom or integer expected by `list_cards/1`.
  """
  @spec parse_mana_value(String.t()) :: non_neg_integer() | :seven_plus
  def parse_mana_value("seven_plus"), do: :seven_plus

  def parse_mana_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> :seven_plus
    end
  end

  @doc "Formats a byte count as a human-readable string (e.g. 4_400_000 -> \"4.2 MB\")."
  @spec format_bytes(non_neg_integer()) :: String.t()
  def format_bytes(bytes) when bytes >= 1_073_741_824 do
    gb = bytes / 1_073_741_824
    "#{:erlang.float_to_binary(gb, decimals: 1)} GB"
  end

  def format_bytes(bytes) when bytes >= 1_048_576 do
    mb = bytes / 1_048_576
    "#{:erlang.float_to_binary(mb, decimals: 1)} MB"
  end

  def format_bytes(bytes) when bytes >= 1024 do
    kb = bytes / 1024
    "#{:erlang.float_to_binary(kb, decimals: 1)} KB"
  end

  def format_bytes(bytes), do: "#{bytes} B"

  @doc "Formats an integer with thousands separators (e.g. 92411 -> \"92,411\")."
  @spec format_count(non_neg_integer()) :: String.t()
  def format_count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_count(other), do: to_string(other)

  @doc "Returns the CSS class for the Oban status dot."
  @spec oban_status_class(boolean()) :: String.t()
  def oban_status_class(true), do: "bg-warning"
  def oban_status_class(false), do: "bg-success"

  # ── URL param encoding / decoding ────────────────────────────────────────

  @doc """
  Builds a URI params map from the current filter state.

  Only includes keys with non-default values so the URL stays clean.
  Param keys:
    * `q`      — search text
    * `colors` — comma-separated mana color codes (W,U,B,R,G,M,C)
    * `r`      — comma-separated rarities
    * `mv`     — comma-separated mana values (0–6 or 7+ for seven_plus)
    * `t`      — comma-separated card types
  """
  @spec params_from_filters(String.t(), MapSet.t(), MapSet.t(), MapSet.t(), MapSet.t()) :: map()
  def params_from_filters(search, colors, rarities, mana_values, types) do
    %{}
    |> put_unless_empty("q", search)
    |> put_unless_empty("colors", encode_set(colors))
    |> put_unless_empty("r", encode_set(rarities))
    |> put_unless_empty("mv", encode_mana_values(mana_values))
    |> put_unless_empty("t", encode_set_atoms(types))
  end

  @doc "Decodes the `q` search param, defaulting to empty string."
  @spec decode_search(map()) :: String.t()
  def decode_search(params), do: Map.get(params, "q", "")

  @doc "Decodes the `colors` param into a MapSet of color code strings."
  @spec decode_colors(map()) :: MapSet.t()
  def decode_colors(params) do
    valid = ~w(W U B R G M C)

    params
    |> Map.get("colors", "")
    |> split_param()
    |> Enum.filter(&(&1 in valid))
    |> MapSet.new()
  end

  @doc "Decodes the `r` param into a MapSet of rarity strings."
  @spec decode_rarities(map()) :: MapSet.t()
  def decode_rarities(params) do
    valid = ~w(common uncommon rare mythic)

    params
    |> Map.get("r", "")
    |> split_param()
    |> Enum.filter(&(&1 in valid))
    |> MapSet.new()
  end

  @doc "Decodes the `mv` param into a MapSet of integers and/or `:seven_plus`."
  @spec decode_mana_values(map()) :: MapSet.t()
  def decode_mana_values(params) do
    params
    |> Map.get("mv", "")
    |> split_param()
    |> Enum.map(fn
      "7+" -> :seven_plus
      n -> parse_mana_value(n)
    end)
    |> MapSet.new()
  end

  @doc "Decodes the `t` param into a MapSet of card type atoms."
  @spec decode_types(map()) :: MapSet.t()
  def decode_types(params) do
    valid = ~w(creature instant sorcery enchantment artifact planeswalker land battle)

    params
    |> Map.get("t", "")
    |> split_param()
    |> Enum.filter(&(&1 in valid))
    |> Enum.map(&String.to_existing_atom/1)
    |> MapSet.new()
  end

  defp put_unless_empty(map, _key, ""), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp encode_set(set), do: set |> MapSet.to_list() |> Enum.sort() |> Enum.join(",")

  defp encode_set_atoms(set) do
    set |> MapSet.to_list() |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(",")
  end

  defp encode_mana_values(set) do
    set
    |> MapSet.to_list()
    |> Enum.map(fn
      :seven_plus -> "7+"
      n -> to_string(n)
    end)
    |> Enum.sort()
    |> Enum.join(",")
  end

  defp split_param(""), do: []
  defp split_param(value) when is_binary(value), do: String.split(value, ",")
end
