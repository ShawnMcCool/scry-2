defmodule Scry2Web.SettingsTabs do
  @moduledoc """
  Shared tab header rendered at the top of each page in the Settings
  group — System (`/`), Operations (`/operations`), and Settings
  (`/settings`). Highlights the active tab based on the current URL
  path and navigates between siblings via `push_navigate`.
  """
  use Phoenix.Component

  use Scry2Web, :verified_routes

  attr :current_path, :string, required: true

  def settings_tabs(assigns) do
    ~H"""
    <div role="tablist" class="tabs tabs-bordered">
      <.link
        role="tab"
        navigate={~p"/"}
        class={["tab", tab_class(@current_path, :system)]}
      >
        System
      </.link>
      <.link
        role="tab"
        navigate={~p"/operations"}
        class={["tab", tab_class(@current_path, :operations)]}
      >
        Operations
      </.link>
      <.link
        role="tab"
        navigate={~p"/settings"}
        class={["tab", tab_class(@current_path, :settings)]}
      >
        Settings
      </.link>
    </div>
    """
  end

  defp tab_class(current_path, :system) do
    if current_path in ["/", "", nil], do: "tab-active", else: ""
  end

  defp tab_class(current_path, :operations) do
    if current_path && String.starts_with?(current_path, "/operations"),
      do: "tab-active",
      else: ""
  end

  defp tab_class(current_path, :settings) do
    if current_path && String.starts_with?(current_path, "/settings"),
      do: "tab-active",
      else: ""
  end
end
