defmodule Scry2.Diagnostics do
  @moduledoc """
  Helpers for inspecting the running scry_2 application from IEx or a
  remote shell.

  Connect via:

      iex --name repl@127.0.0.1 --remsh scry_2_dev@127.0.0.1

  (`Ctrl+\\` disconnects and leaves the server running.)
  """

  alias Scry2.Console
  alias Scry2.Console.EntryView
  alias Scry2.MtgaMemory.SelfTest

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
    |> Enum.each(fn entry -> IO.puts(EntryView.format_line(entry)) end)

    entries
  end

  @doc """
  Runs the memory-reader self-test against the live MTGA process, prints
  the report to stdout, and returns the `%SelfTest.Report{}`.

  Use this after an MTGA update to see which reader walks still work and
  which broke. The printed block is copy-pasteable into a bug report.
  """
  @spec reader_self_test() :: SelfTest.Report.t()
  def reader_self_test do
    report = SelfTest.run()
    IO.puts(SelfTest.to_text(report))
    report
  end
end
