defmodule Scry2Web.Collection.SetDetail.SetPicker do
  @moduledoc """
  Dropdown of all sets known to `Scry2.Cards.SetRoster`. The host LiveView
  must implement `phx-change="pick_set"` and navigate to the matching
  `/collection/sets/:code` URL.
  """

  use Phoenix.Component

  alias Scry2.Cards.Set

  attr :sets, :list, required: true, doc: "Sets in display order (newest first)."
  attr :active_code, :string, required: true

  def set_picker(assigns) do
    ~H"""
    <form phx-change="pick_set" data-role="set-picker">
      <select
        name="code"
        class="select select-sm select-bordered max-w-xs"
        aria-label="Pick a set"
      >
        <option
          :for={set <- @sets}
          value={set.code}
          selected={set.code == @active_code}
        >
          {label(set)}
        </option>
      </select>
    </form>
    """
  end

  defp label(%Set{code: code, name: name}), do: "#{name} (#{code})"
end
