defmodule Scry2.Diagnostics.CrashDump do
  @moduledoc """
  Captures BEAM crash dumps and exposes a brief summary at runtime.

  Erlang writes `erl_crash.dump` to the path in `ERL_CRASH_DUMP` (default:
  the BEAM's CWD) when the VM dies hard. Without intervention the next
  startup's crash silently overwrites the previous dump, and there's no
  in-app way to ask "what killed the previous run?". This module:

  1. On `init!/0`, points future crashes at a stable path under the data
     dir's `log/` subtree so dumps always land somewhere predictable.
  2. If a dump is already there from the previous BEAM, parses a brief
     summary (timestamp, slogan, system version), caches it in
     `:persistent_term` so LiveViews can read it without filesystem IO,
     and rotates the dump aside with a timestamp suffix so the next
     crash doesn't overwrite the evidence.
  3. Keeps at most 5 archived dumps — older ones are removed.

  See `decisions/architecture/` for the broader troubleshooting strategy.
  """

  require Scry2.Log, as: Log

  @latest_summary_key {__MODULE__, :latest_summary}
  @kept 5

  @typedoc """
  Summary parsed from the dump's preamble. `nil` fields when the dump is
  malformed or truncated (still surfaces what we could read).
  """
  @type summary :: %{
          crashed_at: DateTime.t() | nil,
          crashed_at_raw: String.t() | nil,
          slogan: String.t() | nil,
          system_version: String.t() | nil,
          archived_path: String.t() | nil
        }

  @doc """
  Wires `ERL_CRASH_DUMP` to the configured location, harvests any dump
  the previous BEAM left behind, and prunes old archives.

  Accepts an explicit path for testability; defaults to
  `preferred_dump_path/0`. Safe to call multiple times — re-points the
  env var, re-parses any fresh dump. No-ops cleanly when the data dir
  is unwritable (returns `:ok` after logging — never crashes startup).
  """
  @spec init!(Path.t()) :: :ok
  def init!(dump_path \\ preferred_dump_path()) do
    log_dir = Path.dirname(dump_path)

    case File.mkdir_p(log_dir) do
      :ok ->
        System.put_env("ERL_CRASH_DUMP", dump_path)
        harvest!(dump_path)
        prune_archives!(log_dir)
        :ok

      {:error, reason} ->
        Log.warning(
          :system,
          "CrashDump.init! could not create log dir #{log_dir}: #{inspect(reason)}"
        )

        :ok
    end
  end

  @doc "Returns the cached summary of the most recent crash, or `nil`."
  @spec latest_summary() :: summary() | nil
  def latest_summary, do: :persistent_term.get(@latest_summary_key, nil)

  @doc "Path Erlang will write the next crash dump to (data_dir/log/erl_crash.dump)."
  @spec preferred_dump_path() :: String.t()
  def preferred_dump_path do
    Path.join([Scry2.Platform.data_dir(), "log", "erl_crash.dump"])
  end

  @doc """
  Parses the preamble of a dump file. Reads only the first ~4KB —
  everything we want is in the header.
  """
  @spec parse(Path.t()) :: summary()
  def parse(path) do
    head =
      case File.open(path, [:read]) do
        {:ok, fd} ->
          data = IO.binread(fd, 4096)
          File.close(fd)
          if is_binary(data), do: data, else: ""

        _ ->
          ""
      end

    raw_ts = first_match(head, ~r/^([A-Z][a-z]{2} [A-Z][a-z]{2} +\d+ \d+:\d+:\d+ \d{4})$/m)
    slogan = first_match(head, ~r/^Slogan: (.+)$/m)
    sys = first_match(head, ~r/^System version: (.+)$/m)

    %{
      crashed_at: parse_datetime(raw_ts),
      crashed_at_raw: raw_ts,
      slogan: slogan,
      system_version: sys,
      archived_path: nil
    }
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp harvest!(dump_path) do
    case File.stat(dump_path) do
      {:ok, %File.Stat{size: size}} when size > 0 ->
        summary = parse(dump_path)
        archived = archive_path(dump_path, summary.crashed_at)
        :ok = File.rename(dump_path, archived)
        cached = %{summary | archived_path: archived}
        :persistent_term.put(@latest_summary_key, cached)

        Log.warning(
          :system,
          "previous BEAM crashed at #{summary.crashed_at_raw || "unknown time"} — slogan: #{summary.slogan || "?"} (archived to #{archived})"
        )

      _ ->
        :ok
    end
  end

  defp archive_path(dump_path, %DateTime{} = at) do
    suffix = at |> DateTime.to_iso8601(:basic) |> String.replace(":", "")
    archive_with_suffix(dump_path, suffix)
  end

  defp archive_path(dump_path, _),
    do:
      archive_with_suffix(
        dump_path,
        DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
      )

  defp archive_with_suffix(dump_path, suffix) do
    Path.join(Path.dirname(dump_path), "erl_crash-#{suffix}.dump")
  end

  defp prune_archives!(log_dir) do
    archives =
      log_dir
      |> Path.join("erl_crash-*.dump")
      |> Path.wildcard()
      |> Enum.sort(:desc)

    Enum.drop(archives, @kept)
    |> Enum.each(fn path ->
      _ = File.rm(path)
    end)
  end

  defp first_match(head, regex) do
    case Regex.run(regex, head) do
      [_, capture] -> String.trim(capture)
      _ -> nil
    end
  end

  # Erlang's crash dump timestamp uses C `ctime()` format:
  # "Tue Apr 28 23:51:01 2026". Parse manually — no stdlib parser handles it.
  defp parse_datetime(nil), do: nil

  defp parse_datetime(string) when is_binary(string) do
    case Regex.run(
           ~r/^([A-Z][a-z]{2}) ([A-Z][a-z]{2}) +(\d+) (\d+):(\d+):(\d+) (\d{4})$/,
           string
         ) do
      [_, _wday, mon, day, h, m, s, year] ->
        with {:ok, month} <- month_to_int(mon),
             {:ok, date} <-
               Date.new(String.to_integer(year), month, String.to_integer(day)),
             {:ok, time} <-
               Time.new(
                 String.to_integer(h),
                 String.to_integer(m),
                 String.to_integer(s)
               ) do
          DateTime.new!(date, time, "Etc/UTC")
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  defp month_to_int(abbr) do
    case Map.fetch(@months, abbr) do
      {:ok, n} -> {:ok, n}
      :error -> :error
    end
  end
end
