defmodule Scry2.Log do
  @moduledoc """
  Component-tagged log macros for Scry2 thinking logs.

  ## Usage

      require Scry2.Log, as: Log
      Log.info(:ingester, "processed 3 events")
      Log.info(:http, fn -> "response: \#{inspect(data, limit: 5)}" end)
      Log.warning(:watcher, "backlog: \#{count} events")
      Log.error(:importer, "failed to persist card: \#{inspect(reason)}")

  Log visibility is controlled in the browser via the Console drawer
  (press `` ` `` from any page) or the full-page `/console` route. All captured
  entries land in `Scry2.Console.Buffer` and can be filtered at display
  time by component, level, and text search.

  ## Components

  Domain tags (always use these in `Scry2.*` call sites):

  | Component   | Use for                                           |
  |-------------|---------------------------------------------------|
  | `:watcher`  | `Player.log` file events, tail progress           |
  | `:parser`   | MTGA event parsing, unknown event types           |
  | `:ingester` | Raw-event persistence, downstream dispatch        |
  | `:importer` | 17lands CSV import, Scryfall backfill             |
  | `:http`     | API calls, rate limiting, fetch results           |
  | `:system`   | Fallback for anything without a tag               |

  Framework components (`:phoenix`, `:ecto`, `:live_view`) are assigned
  automatically by `Scry2.Console.Handler` based on the emitting module.

  ## Message Format

  - Lowercase, no trailing period: `"imported 23891 cards"`
  - No component prefix in the message itself — the `:component` metadata
    drives the badge in the UI and the `[component]` tag in stdout
  - Include key identifiers: card arena_id, match mtga_id, file path basename
  - Shorten paths with `Path.basename/1` when the full path adds noise
  - For decisions, log outcome AND reason:
    `"skipped card arena_id=69420 — already backfilled"`
  - Use `fn -> ... end` for messages with expensive interpolation — the
    function only runs if the log level passes
  """

  @doc "Emits an info-level log tagged with the given component."
  defmacro info(component, message) do
    quote do
      require Logger
      Logger.info(unquote(message), component: unquote(component))
    end
  end

  @doc "Emits a warning-level log tagged with the given component."
  defmacro warning(component, message) do
    quote do
      require Logger
      Logger.warning(unquote(message), component: unquote(component))
    end
  end

  @doc "Emits an error-level log tagged with the given component."
  defmacro error(component, message) do
    quote do
      require Logger
      Logger.error(unquote(message), component: unquote(component))
    end
  end
end
