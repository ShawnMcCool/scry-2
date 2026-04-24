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
  attr :current_path, :string, default: "/"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8 border-b border-base-300">
      <div class="flex-1 flex items-center gap-5">
        <.link navigate={~p"/"} class="flex items-center gap-2 text-lg font-semibold font-beleren">
          <.icon name="hero-eye" class="size-6 text-primary" /> Scry&nbsp;2
        </.link>
        <div class="w-px h-5 bg-base-300"></div>
        <nav class="flex gap-1">
          <.nav_link path={~p"/matches"} label="Matches" current_path={@current_path} />
          <.nav_link path={~p"/decks"} label="Decks" current_path={@current_path} />
          <.nav_link path={~p"/drafts"} label="Drafts" current_path={@current_path} />
          <.nav_link path={~p"/cards"} label="Cards" current_path={@current_path} />
          <.nav_link path={~p"/player"} label="Player" current_path={@current_path} />
          <.nav_link path={~p"/ranks"} label="Ranks" current_path={@current_path} />
          <.nav_link path={~p"/economy"} label="Economy" current_path={@current_path} />
          <.nav_link path={~p"/collection"} label="Collection" current_path={@current_path} />
        </nav>
      </div>
      <div class="flex-none flex items-center gap-3">
        <.profile_dropdown
          players={@players}
          active_player_id={@active_player_id}
          current_path={@current_path}
        />
        <.gear_link current_path={@current_path} />
      </div>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto space-y-6" style="max-width: min(90vw, 1400px)">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :path, :string, required: true
  attr :label, :string, required: true
  attr :current_path, :string, required: true

  defp nav_link(assigns) do
    assigns = assign(assigns, :active, String.starts_with?(assigns.current_path, assigns.path))

    ~H"""
    <.link
      navigate={@path}
      class={[
        "px-3 py-1.5 rounded-md text-sm font-medium transition-colors",
        if(@active,
          do: "bg-primary/10 text-primary",
          else: "text-base-content/60 hover:text-base-content"
        )
      ]}
    >
      {@label}
    </.link>
    """
  end

  attr :players, :list, required: true
  attr :active_player_id, :integer, default: nil
  attr :current_path, :string, required: true

  defp profile_dropdown(assigns) do
    active_player = Enum.find(assigns.players, &(&1.id == assigns.active_player_id))

    assigns =
      assign(assigns,
        display_name: if(active_player, do: active_player.screen_name, else: "All Players"),
        avatar_letter: if(active_player, do: String.first(active_player.screen_name), else: "?")
      )

    ~H"""
    <details
      id="profile-dropdown"
      class="dropdown dropdown-end"
      phx-click-away={close_dropdown("profile-dropdown")}
    >
      <summary
        class="btn btn-ghost btn-sm gap-2 border border-base-300 px-3"
        phx-click={close_dropdown("gear-dropdown")}
      >
        <div class="w-5 h-5 rounded-full bg-gradient-to-br from-primary to-primary/70 flex items-center justify-center">
          <span class="text-[10px] font-bold text-primary-content">{@avatar_letter}</span>
        </div>
        <span class="text-sm text-base-content/70">{@display_name}</span>
        <.icon name="hero-chevron-down" class="size-3 text-base-content/40" />
      </summary>
      <div class="dropdown-content z-50 mt-2 w-52 rounded-lg border border-base-300 bg-base-200 shadow-xl p-2">
        <div
          :for={player <- @players}
          phx-click="select_player"
          phx-value-player_id={player.id}
          class={[
            "w-full text-left px-3 py-1.5 rounded-md text-sm cursor-pointer",
            if(player.id == @active_player_id,
              do: "bg-primary/10 text-primary font-medium",
              else: "text-base-content/60 hover:bg-base-300"
            )
          ]}
        >
          {player.screen_name}
        </div>
        <div
          phx-click="select_player"
          phx-value-player_id=""
          class={[
            "w-full text-left px-3 py-1.5 rounded-md text-sm cursor-pointer",
            if(is_nil(@active_player_id),
              do: "bg-primary/10 text-primary font-medium",
              else: "text-base-content/60 hover:bg-base-300"
            )
          ]}
        >
          All Players
        </div>
      </div>
    </details>
    """
  end

  attr :current_path, :string, required: true

  defp gear_link(assigns) do
    assigns = assign(assigns, :active, settings_group?(assigns.current_path))

    ~H"""
    <.link
      navigate={~p"/"}
      class={[
        "btn btn-ghost btn-sm btn-square border border-base-300",
        @active && "text-primary"
      ]}
    >
      <.icon name="hero-cog-6-tooth" class="size-4 text-base-content/50" />
    </.link>
    """
  end

  defp settings_group?(nil), do: false
  defp settings_group?("/"), do: true
  defp settings_group?("/operations" <> _), do: true
  defp settings_group?("/settings" <> _), do: true
  defp settings_group?(_), do: false

  defp close_dropdown(id) do
    JS.remove_attribute("open", to: "##{id}")
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
end
