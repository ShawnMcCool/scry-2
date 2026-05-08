defmodule Scry2Web.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use Scry2Web, :html

  alias Scry2Web.NavHelpers

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

  attr :nav_update, :map,
    default: %{summary: %{status: :no_data, checking: false}},
    doc: "set by Scry2Web.NavUpdateScope on_mount; powers the gear update badge"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar flex-nowrap px-4 sm:px-6 lg:px-8 border-b border-base-300">
      <div class="flex-1 min-w-0 flex items-center gap-5">
        <.link
          navigate={~p"/"}
          class="flex items-center gap-2 text-lg font-semibold font-beleren shrink-0"
        >
          <.icon name="hero-eye" class="size-6 text-primary" /> Scry&nbsp;2
        </.link>
        <div class="w-px h-5 bg-base-300 shrink-0"></div>

        <nav class="hidden lg:flex gap-1 min-w-0">
          <.nav_link
            :for={item <- NavHelpers.items()}
            path={item.path}
            label={item.label}
            current_path={@current_path}
          />
        </nav>

        <.nav_overflow_dropdown current_path={@current_path} />
      </div>

      <div class="ml-auto flex-shrink-0 flex items-center gap-3">
        <.profile_dropdown
          players={@players}
          active_player_id={@active_player_id}
          current_path={@current_path}
        />
        <.gear_dropdown current_path={@current_path} nav_update={@nav_update} />
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
        display_name: if(active_player, do: player_label(active_player), else: "All Players"),
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
          {player_label(player)}
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
  attr :nav_update, :map, required: true

  defp gear_dropdown(assigns) do
    indicator = NavHelpers.gear_indicator(assigns.nav_update)

    assigns =
      assign(assigns,
        active: settings_group?(assigns.current_path),
        indicator: indicator
      )

    ~H"""
    <details
      id="gear-dropdown"
      class="dropdown dropdown-end"
      phx-click-away={close_dropdown("gear-dropdown")}
    >
      <summary
        class={[
          "btn btn-ghost btn-sm gap-1.5 border border-base-300 px-2",
          @active && "text-primary"
        ]}
        phx-click={close_dropdown("profile-dropdown")}
      >
        <.icon name="hero-cog-6-tooth" class="size-4 text-base-content/60" />
        <span
          :if={@indicator.kind == :badge}
          class="badge badge-xs badge-soft badge-info"
        >
          {@indicator.label}
        </span>
      </summary>
      <div class="dropdown-content z-50 mt-2 w-56 rounded-lg border border-base-300 bg-base-200 shadow-xl p-2">
        <.gear_menu_item
          path={~p"/"}
          label="System"
          icon="hero-heart"
          current_path={@current_path}
          exact?
        />
        <.gear_menu_item
          path={~p"/operations"}
          label="Operations"
          icon="hero-wrench-screwdriver"
          current_path={@current_path}
        />
        <.link
          navigate={~p"/settings"}
          phx-click={close_dropdown("gear-dropdown")}
          class={[
            "flex items-center gap-2 px-3 py-1.5 rounded-md text-sm",
            if(NavHelpers.active?(@current_path, "/settings"),
              do: "bg-primary/10 text-primary font-medium",
              else: "text-base-content/70 hover:bg-base-300"
            )
          ]}
        >
          <.icon name="hero-cog-6-tooth" class="size-4" />
          <span>Settings</span>
          <span
            :if={@indicator.kind == :badge}
            class="badge badge-xs badge-soft badge-info ml-auto"
          >
            {@indicator.label}
          </span>
        </.link>
        <.gear_menu_item
          path={~p"/console"}
          label="Console"
          icon="hero-command-line"
          current_path={@current_path}
        />
      </div>
    </details>
    """
  end

  attr :path, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :current_path, :string, required: true
  attr :exact?, :boolean, default: false

  defp gear_menu_item(assigns) do
    active =
      if assigns.exact? do
        assigns.current_path == assigns.path
      else
        NavHelpers.active?(assigns.current_path, assigns.path)
      end

    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@path}
      phx-click={close_dropdown("gear-dropdown")}
      class={[
        "flex items-center gap-2 px-3 py-1.5 rounded-md text-sm",
        if(@active,
          do: "bg-primary/10 text-primary font-medium",
          else: "text-base-content/70 hover:bg-base-300"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
  end

  attr :current_path, :string, required: true

  defp nav_overflow_dropdown(assigns) do
    ~H"""
    <details
      id="nav-overflow-dropdown"
      class="dropdown lg:hidden"
      phx-click-away={close_dropdown("nav-overflow-dropdown")}
    >
      <summary class="btn btn-ghost btn-sm btn-square border border-base-300">
        <.icon name="hero-bars-3" class="size-4 text-base-content/70" />
      </summary>
      <div class="dropdown-content z-50 mt-2 w-56 rounded-lg border border-base-300 bg-base-200 shadow-xl p-2">
        <.link
          :for={item <- NavHelpers.items()}
          navigate={item.path}
          phx-click={close_dropdown("nav-overflow-dropdown")}
          class={[
            "block px-3 py-1.5 rounded-md text-sm",
            if(NavHelpers.active?(@current_path, item.path),
              do: "bg-primary/10 text-primary font-medium",
              else: "text-base-content/70 hover:bg-base-300"
            )
          ]}
        >
          {item.label}
        </.link>
      </div>
    </details>
    """
  end

  defp settings_group?(nil), do: false
  defp settings_group?("/"), do: true
  defp settings_group?("/operations" <> _), do: true
  defp settings_group?("/settings" <> _), do: true
  defp settings_group?("/console" <> _), do: true
  defp settings_group?(_), do: false

  # Layout-side helper: prefer the memory-read DisplayName-with-discriminator
  # (e.g. "Shawn McCool#91813") when the walker has populated it, falling
  # back to the bare screen_name from log events. Pure function, kept tiny
  # so it can sit inline in this layout module.
  defp player_label(%{mtga_display_name: name}) when is_binary(name) and name != "", do: name
  defp player_label(%{screen_name: name}), do: name

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
