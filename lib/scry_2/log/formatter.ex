defmodule Scry2.Log.Formatter do
  @moduledoc """
  Custom log formatter that renders component-tagged logs as
  `[level][component] message` and normal logs as `[level] message`.

  Wired in `config/dev.exs` and `config/prod.exs` via:

      config :logger, :default_formatter,
        format: {Scry2.Log.Formatter, :format}

  This only affects the `:default` stdout handler. The in-browser
  Console drawer uses `Scry2.Console.Handler`, which parses the
  `:component` metadata directly and renders its own badges.
  """

  def format(level, message, _timestamp, metadata) do
    case Keyword.get(metadata, :component) do
      nil -> "[#{level}] #{message}\n"
      component -> "[#{level}][#{component}] #{message}\n"
    end
  rescue
    _ -> "[#{level}] #{message}\n"
  end
end
