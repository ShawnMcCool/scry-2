defmodule Scry2Web.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use Scry2Web, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :players, :list, default: []
  attr :active_player_id, :integer, default: nil

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8 border-b border-base-300">
      <div class="flex-1">
        <.link navigate={~p"/"} class="flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-eye" class="size-6 text-primary" /> Scry2
        </.link>
      </div>
      <div class="flex-none">
        <ul class="menu menu-horizontal gap-2">
          <li><.link navigate={~p"/"}>Dashboard</.link></li>
          <li><.link navigate={~p"/matches"}>Matches</.link></li>
          <li><.link navigate={~p"/drafts"}>Drafts</.link></li>
          <li><.link navigate={~p"/cards"}>Cards</.link></li>
          <li><.link navigate={~p"/settings"}>Settings</.link></li>
          <li>
            <.player_selector players={@players} active_player_id={@active_player_id} />
          </li>
          <li><.theme_toggle /></li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-6xl space-y-6">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders the persistent Guake-style console LiveView as a sticky child of
  the root layout. Mounted once from `root.html.heex` so it survives page
  navigation within the `:browser` live_session.
  """
  attr :socket, :any, required: true

  def console_mount(assigns) do
    ~H"""
    {live_render(@socket, Scry2Web.ConsoleLive, id: "console-sticky", sticky: true)}
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Player filter dropdown. Always visible in the nav — shows "All Players"
  plus one option per auto-discovered player.
  """
  attr :players, :list, required: true
  attr :active_player_id, :integer, default: nil

  def player_selector(assigns) do
    ~H"""
    <form phx-change="select_player">
      <select name="player_id" class="select select-sm select-bordered w-40">
        <option value="" selected={is_nil(@active_player_id)}>All Players</option>
        <option
          :for={player <- @players}
          value={player.id}
          selected={player.id == @active_player_id}
        >
          {player.screen_name}
        </option>
      </select>
    </form>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
