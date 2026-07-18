defmodule Scry2Web.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use Scry2Web, :html

  alias Scry2Web.NavHelpers
  alias Scry2Web.SidebarNav

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

  attr :sidebar_collapsed, :boolean,
    default: false,
    doc: "set by Scry2Web.SidebarScope on_mount; powers the rail toggle"

  attr :catch_up_status, :map,
    default: %{caught_up: true, lag: 0, projectors_behind: []},
    doc: "set by Scry2Web.CatchUpScope on_mount; surfaces post-update absorption progress"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden">
      <.sidebar
        collapsed={@sidebar_collapsed}
        current_path={@current_path}
        nav_update={@nav_update}
      />

      <div class="flex flex-col flex-1 min-w-0">
        <header class="navbar flex-nowrap shrink-0 px-4 sm:px-6 lg:px-8 border-b border-base-300">
          <div class="ml-auto flex-shrink-0 flex items-center gap-3">
            <.profile_dropdown
              players={@players}
              active_player_id={@active_player_id}
              current_path={@current_path}
            />
          </div>
        </header>

        <.catch_up_banner status={@catch_up_status} />

        <main class="flex-1 min-w-0 overflow-y-auto px-4 py-8 sm:px-6 lg:px-8">
          <div class="mx-auto space-y-6" style="max-width: min(90vw, 1400px)">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :status, :map, required: true

  defp catch_up_banner(assigns) do
    ~H"""
    <div
      :if={not @status.caught_up}
      class="bg-info/10 border-b border-info/20 px-4 sm:px-6 lg:px-8 py-2"
      role="status"
      aria-live="polite"
    >
      <div
        class="flex items-center gap-3 text-sm text-base-content/80"
        style="max-width: min(90vw, 1400px); margin: 0 auto;"
      >
        <span class="loading loading-spinner loading-xs text-info" aria-hidden="true"></span>
        <span>
          Catching up on event log —
          <span class="tabular-nums font-medium">{format_lag(@status.lag)}</span>
          events behind across {length(@status.projectors_behind)} {projector_word(
            @status.projectors_behind
          )}. Some pages may show partial data for a minute.
        </span>
      </div>
    </div>
    """
  end

  defp format_lag(lag) when lag >= 1_000, do: "#{Float.round(lag / 1_000, 1)}k"
  defp format_lag(lag), do: Integer.to_string(lag)

  defp projector_word([_]), do: "projector"
  defp projector_word(_), do: "projectors"

  attr :collapsed, :boolean, required: true
  attr :current_path, :string, required: true
  attr :nav_update, :map, required: true

  defp sidebar(assigns) do
    ~H"""
    <aside
      class={[
        "shrink-0 border-r border-base-300 bg-base-200 py-3 flex flex-col gap-1 overflow-y-auto",
        if(@collapsed, do: "w-14 px-1", else: "w-56 px-2")
      ]}
      data-role="sidebar"
      data-collapsed={to_string(@collapsed)}
    >
      <div class={[
        "flex items-center",
        if(@collapsed, do: "flex-col gap-1", else: "justify-between px-1")
      ]}>
        <.link
          id="rail-brand"
          navigate={~p"/"}
          phx-hook="RailTip"
          data-tip={if(@collapsed, do: "Scry 2", else: nil)}
          class="flex items-center gap-2 text-base-content hover:text-primary transition-colors"
        >
          <.icon name="hero-eye" class="size-6 text-primary shrink-0" />
          <span
            :if={not @collapsed}
            class="text-lg font-semibold font-beleren leading-none whitespace-nowrap"
          >
            Scry&nbsp;2
          </span>
        </.link>
        <.sidebar_toggle collapsed={@collapsed} />
      </div>

      <hr class="border-base-300 my-1" aria-hidden="true" />

      <%= for {section, index} <- Enum.with_index(SidebarNav.sections()) do %>
        <hr
          :if={index > 0}
          class="border-base-300 my-1"
          aria-hidden="true"
        />
        <p
          :if={section.label && not @collapsed}
          class="text-[10px] uppercase tracking-wider text-base-content/50 px-2 pt-1"
        >
          {section.label}
        </p>
        <.sidebar_item
          :for={item <- section.items}
          item={item}
          collapsed={@collapsed}
          current_path={@current_path}
        />
      <% end %>

      <hr class="border-base-300 mt-auto mb-1" aria-hidden="true" />
      <.sidebar_settings
        collapsed={@collapsed}
        current_path={@current_path}
        nav_update={@nav_update}
      />
    </aside>
    """
  end

  attr :collapsed, :boolean, required: true
  attr :current_path, :string, required: true
  attr :nav_update, :map, required: true

  defp sidebar_settings(assigns) do
    assigns =
      assign(assigns,
        active: settings_group?(assigns.current_path),
        indicator: NavHelpers.gear_indicator(assigns.nav_update)
      )

    ~H"""
    <.link
      id="rail-settings"
      navigate={~p"/system"}
      phx-hook="RailTip"
      data-tip={if(@collapsed, do: "Settings", else: nil)}
      class={[
        "relative flex items-center rounded-md text-sm font-medium transition-colors",
        if(@collapsed, do: "justify-center px-1 py-2", else: "gap-2.5 px-2 py-1.5"),
        if(@active,
          do: "bg-primary/10 text-primary",
          else: "text-base-content/70 hover:text-base-content hover:bg-base-300/60"
        )
      ]}
      data-role="sidebar-settings"
      aria-label="Settings"
    >
      <.icon name="hero-cog-6-tooth" class="size-4 shrink-0" />
      <span :if={not @collapsed} class="truncate">Settings</span>
      <span
        :if={not @collapsed and @indicator.kind == :badge}
        class="ml-auto badge badge-xs badge-soft badge-info"
      >
        {@indicator.label}
      </span>
      <span
        :if={@collapsed and @indicator.kind == :badge}
        class="absolute top-1 right-1.5 size-2 rounded-full bg-info"
        aria-hidden="true"
      >
      </span>
    </.link>
    """
  end

  attr :collapsed, :boolean, required: true

  defp sidebar_toggle(assigns) do
    ~H"""
    <button
      id="rail-toggle"
      type="button"
      phx-click="toggle_sidebar"
      phx-hook="RailTip"
      class={[
        "flex items-center text-base-content/50 hover:text-base-content",
        "h-7 rounded-md hover:bg-base-300/60 transition-colors",
        if(@collapsed, do: "justify-center", else: "justify-end px-2")
      ]}
      data-tip={if(@collapsed, do: "Expand sidebar", else: nil)}
      aria-label={if(@collapsed, do: "Expand sidebar", else: "Collapse sidebar")}
      data-role="sidebar-toggle"
    >
      <.icon
        name={if(@collapsed, do: "hero-chevron-double-right", else: "hero-chevron-double-left")}
        class="size-3.5"
      />
    </button>
    """
  end

  attr :item, :map, required: true
  attr :collapsed, :boolean, required: true
  attr :current_path, :string, required: true

  defp sidebar_item(assigns) do
    assigns =
      assigns
      |> assign(:active, SidebarNav.active?(assigns.current_path, assigns.item.path))
      |> assign(:dom_id, "rail-item-" <> rail_slug(assigns.item.path))

    ~H"""
    <.link
      id={@dom_id}
      navigate={@item.path}
      phx-hook="RailTip"
      class={[
        "flex items-center rounded-md text-sm font-medium transition-colors",
        if(@collapsed, do: "justify-center px-1 py-2", else: "gap-2.5 px-2 py-1.5"),
        if(@active,
          do: "bg-primary/10 text-primary",
          else: "text-base-content/70 hover:text-base-content hover:bg-base-300/60"
        )
      ]}
      data-tip={if(@collapsed, do: @item.label, else: nil)}
      data-role="sidebar-item"
      data-path={@item.path}
    >
      <.icon name={@item.icon} class="size-4 shrink-0" />
      <span :if={not @collapsed} class="truncate">{@item.label}</span>
    </.link>
    """
  end

  # DOM-id-safe slug for a nav path: "/collection" -> "collection".
  defp rail_slug(path) do
    path
    |> String.trim_leading("/")
    |> String.replace("/", "-")
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
      <summary class="btn btn-ghost btn-sm gap-2 border border-base-300 px-3">
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

  defp settings_group?(nil), do: false
  defp settings_group?("/system" <> _), do: true
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
