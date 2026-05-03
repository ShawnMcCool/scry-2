defmodule Scry2.Console.DisplayHelpers do
  @moduledoc """
  Pure helpers for rendering `Scry2.Console.Entry` records in LiveViews.
  No Phoenix, no LiveView, no DB dependencies. Testable with `async: true`.

  Component display order, badge palette, level colors, and plain-text
  rendering for download/copy actions all live here. LiveView templates
  and `ConsoleComponents` are pure consumers of these helpers.
  """

  alias Scry2.Console.Entry

  # Grouped for the chip row; app first, then framework.
  # Must stay in sync with CLAUDE.md's Thinking Logs > Components table.
  @known_components [
    # app/domain
    :watcher,
    :parser,
    :ingester,
    :importer,
    :http,
    :live_state,
    :system,
    # framework
    :phoenix,
    :ecto,
    :live_view
  ]

  @app_components [:watcher, :parser, :ingester, :importer, :http, :live_state, :system]
  @framework_components [:phoenix, :ecto, :live_view]

  @badge_palette [
    "badge-primary",
    "badge-secondary",
    "badge-accent",
    "badge-info",
    "badge-success",
    "badge-warning"
  ]

  @doc "All component atoms in display order — app first, then framework."
  @spec known_components() :: [atom()]
  def known_components, do: @known_components

  @doc "App-layer component atoms."
  @spec app_components() :: [atom()]
  def app_components, do: @app_components

  @doc "Framework component atoms."
  @spec framework_components() :: [atom()]
  def framework_components, do: @framework_components

  @doc """
  Formats a UTC `%DateTime{}` as `"HH:MM:SS.mmm"` in the local system timezone.
  Falls back to the UTC representation if the zone shift fails.
  """
  @spec format_timestamp(DateTime.t()) :: String.t()
  def format_timestamp(%DateTime{} = datetime) do
    local =
      case DateTime.shift_zone(datetime, "Etc/UTC") do
        {:ok, shifted} -> shifted
        {:error, _} -> datetime
      end

    hour = local.hour |> Integer.to_string() |> String.pad_leading(2, "0")
    minute = local.minute |> Integer.to_string() |> String.pad_leading(2, "0")
    second = local.second |> Integer.to_string() |> String.pad_leading(2, "0")

    ms =
      local
      |> DateTime.to_time()
      |> then(fn time ->
        {microseconds, _precision} = time.microsecond
        div(microseconds, 1000)
      end)
      |> Integer.to_string()
      |> String.pad_leading(3, "0")

    "#{hour}:#{minute}:#{second}.#{ms}"
  end

  @doc """
  Returns the DaisyUI text color class for a log level.
  """
  @spec level_color(Entry.level()) :: String.t()
  def level_color(:error), do: "text-error"
  def level_color(:warning), do: "text-warning"
  def level_color(:info), do: "text-info"
  def level_color(:debug), do: "text-base-content/60"

  @doc """
  Returns a human-readable label for a component atom.
  Returns `"system"` for `nil`.
  """
  @spec component_label(atom() | nil) :: String.t()
  def component_label(nil), do: "system"
  def component_label(component), do: Atom.to_string(component)

  @doc """
  Returns a deterministic DaisyUI badge class for a component atom,
  based on `:erlang.phash2/2` mapped into a 6-element palette.
  Returns `"badge-ghost"` for `nil`.
  """
  @spec component_badge_class(atom() | nil) :: String.t()
  def component_badge_class(nil), do: "badge-ghost"

  def component_badge_class(component) do
    index = :erlang.phash2(component, length(@badge_palette))
    Enum.at(@badge_palette, index)
  end

  @doc """
  Formats a single `%Entry{}` as a plain-text line for download or copy output.
  Format: `"[HH:MM:SS.mmm] [level] [component] message"`
  """
  @spec format_line(Entry.t()) :: String.t()
  def format_line(%Entry{} = entry) do
    timestamp = format_timestamp(entry.timestamp)
    level = Atom.to_string(entry.level)
    component = component_label(entry.component)
    "[#{timestamp}] [#{level}] [#{component}] #{entry.message}"
  end

  @doc """
  Formats a list of entries (newest-first) as a multi-line plain-text string.
  Reverses to chronological order, then joins with `"\\n"`.
  """
  @spec format_lines([Entry.t()]) :: String.t()
  def format_lines([]), do: ""

  def format_lines(entries) do
    entries
    |> Enum.reverse()
    |> Enum.map(&format_line/1)
    |> Enum.join("\n")
  end

  @doc """
  Returns a CSS class indicating whether a component chip is active or inactive.
  Active means the component is set to `:show` in the filter (or defaults to show).
  """
  @spec chip_state_class(Scry2.Console.Filter.t(), atom()) :: String.t()
  def chip_state_class(%{components: components, default_component: default_component}, component) do
    visibility = Map.get(components, component, default_component)

    case visibility do
      :show -> "console-chip-active"
      :hide -> "console-chip-inactive"
    end
  end

  @doc """
  Returns the DaisyUI button class for a level filter button.
  Returns `"btn-active"` when the filter's level matches the given level,
  otherwise returns `""`.
  """
  @spec level_button_class(Scry2.Console.Filter.t(), atom()) :: String.t()
  def level_button_class(%{level: filter_level}, level) do
    if filter_level == level, do: "btn-active", else: ""
  end

  @doc """
  Returns a lowercase string of the entry's message suitable for the
  `data-message` attribute used by client-side search filtering.
  """
  @spec entry_search_text(Entry.t()) :: String.t()
  def entry_search_text(%Entry{message: message}), do: String.downcase(message)

  @doc """
  Returns the button label for the pause/resume toggle.
  """
  @spec pause_button_label(boolean()) :: String.t()
  def pause_button_label(true), do: "resume"
  def pause_button_label(false), do: "pause"

  @doc """
  Returns `true` if two filters differ only in their `:search` field.
  Used to skip server-side re-streaming when text search changes — the
  client-side hook handles DOM filtering via `data-message` attributes.
  """
  @spec only_search_changed?(
          Scry2.Console.Filter.t(),
          Scry2.Console.Filter.t()
        ) :: boolean()
  def only_search_changed?(filter_a, filter_b) do
    normalize = fn filter -> %{filter | search: ""} end
    filter_a.search != filter_b.search and normalize.(filter_a) == normalize.(filter_b)
  end
end
