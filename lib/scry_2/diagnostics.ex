defmodule Scry2.Diagnostics do
  @moduledoc """
  Helpers for inspecting the running scry_2 application from IEx or a
  remote shell.

  Connect via:

      iex --name repl@127.0.0.1 --remsh scry_2_dev@127.0.0.1

  (`Ctrl+\\` disconnects and leaves the server running.)
  """

  alias Scry2.Console
  alias Scry2.Console.View

  @doc """
  Prints the most recent `n` log entries to stdout (default 20) and returns
  them as a list of `%Scry2.Console.Entry{}`.

  Entries are returned newest-first. The printed format mirrors the
  download/copy format used by the browser console drawer:

      [HH:MM:SS.mmm] [level] [component] message
  """
  @spec log_recent(pos_integer()) :: [Console.Entry.t()]
  def log_recent(n \\ 20) when is_integer(n) and n > 0 do
    entries = Console.recent_entries(n)

    entries
    |> Enum.reverse()
    |> Enum.each(fn entry -> IO.puts(View.format_line(entry)) end)

    entries
  end
end
