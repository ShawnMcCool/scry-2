defmodule Scry2.LiveState.IntList do
  @moduledoc """
  Ecto type that stores a list of integers as a JSON-text column.

  Used by `Scry2.LiveState.Snapshot` for the `commander_grp_ids`
  fields. Avoids a separate join table for what is always 1 or 2
  arena_ids per match.

  The on-disk shape is a JSON array literal (e.g. `"[74116,74117]"`).
  An empty list round-trips as `"[]"`. `nil` is preserved.
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(nil), do: {:ok, nil}

  def cast(list) when is_list(list) do
    if Enum.all?(list, &is_integer/1), do: {:ok, list}, else: :error
  end

  def cast(_), do: :error

  @impl true
  def load(nil), do: {:ok, nil}
  def load(""), do: {:ok, []}

  def load(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_integer/1), do: {:ok, list}, else: :error

      _ ->
        :error
    end
  end

  @impl true
  def dump(nil), do: {:ok, nil}

  def dump(list) when is_list(list) do
    if Enum.all?(list, &is_integer/1) do
      {:ok, Jason.encode!(list)}
    else
      :error
    end
  end

  def dump(_), do: :error
end
