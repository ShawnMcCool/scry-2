defmodule Scry2.Console.CaptureLogOutput do
  @moduledoc """
  Erlang `:logger` handler that funnels all log events into
  `Scry2.Console.RecentEntries`.

  Installed once in `Scry2.Application.start/2` via `:logger.add_handler/3`.
  Runs in the caller's process context for each log call, so it must be
  cheap and crash-free.

  The handler never broadcasts directly — it casts to the Buffer GenServer,
  which owns the PubSub broadcast. This avoids reentrancy if PubSub itself
  logs during broadcast.

  Entries tagged with `scry2_log_source: :buffer` in metadata are dropped —
  that's the Buffer's own reentrancy guard for its failure logs.
  """

  @behaviour :logger_handler

  alias Scry2.Console.Entry

  @doc false
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    try do
      unless meta[:scry2_log_source] == :buffer do
        entry = build_entry(level, msg, meta)
        Scry2.Console.RecentEntries.append(entry)
      end
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  # :logger handler lifecycle callbacks

  @doc false
  def adding_handler(config), do: {:ok, config}

  @doc false
  def removing_handler(_config), do: :ok

  @doc false
  def changing_config(_op, _old, new), do: {:ok, new}

  # --- Public for testing ---

  @doc false
  @spec build_entry(atom(), term(), map()) :: Entry.t()
  def build_entry(level, msg, meta) do
    %Entry{
      id: System.unique_integer([:monotonic, :positive]),
      timestamp: DateTime.utc_now(),
      level: normalize_level(level),
      component: classify_component(meta),
      module: module_from_meta(meta),
      message: render_message(msg),
      metadata: prune_metadata(meta)
    }
  end

  # --- Private ---

  # Level normalization: collapse Erlang levels to the four we care about.
  defp normalize_level(:debug), do: :debug
  defp normalize_level(:info), do: :info
  defp normalize_level(:notice), do: :info
  defp normalize_level(:warning), do: :warning
  # legacy Elixir Logger atom
  defp normalize_level(:warn), do: :warning
  defp normalize_level(:error), do: :error
  defp normalize_level(:critical), do: :error
  defp normalize_level(:alert), do: :error
  defp normalize_level(:emergency), do: :error
  defp normalize_level(_), do: :info

  # Component classification — every entry gets exactly one component atom.
  # Explicit :component metadata wins; otherwise classify from module prefix.
  defp classify_component(meta) do
    cond do
      is_atom(meta[:component]) and meta[:component] != nil ->
        meta[:component]

      true ->
        meta
        |> module_from_meta()
        |> classify_module()
    end
  end

  defp classify_module(nil), do: :system

  defp classify_module(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> classify_module_name()
  end

  # Strip Elixir. prefix before pattern matching.
  defp classify_module_name("Elixir." <> rest), do: classify_module_name(rest)
  # LiveView must be checked before Phoenix to match more specifically.
  defp classify_module_name("Phoenix.LiveView" <> _), do: :live_view
  defp classify_module_name("Phoenix" <> _), do: :phoenix
  defp classify_module_name("Ecto" <> _), do: :ecto
  # scry_2 uses SQLite via Exqlite (not Postgrex).
  defp classify_module_name("Exqlite" <> _), do: :ecto
  defp classify_module_name("DBConnection" <> _), do: :ecto
  # Auto-classify the live-polling subsystem so any log emitted from
  # there without an explicit :component tag still lands on the right
  # console chip.
  defp classify_module_name("Scry2.LiveState" <> _), do: :live_state
  defp classify_module_name(_), do: :system

  # Extract module atom from meta[:mfa] (tuple: {module, fun, arity}).
  defp module_from_meta(meta) do
    case meta[:mfa] do
      {module, _, _} when is_atom(module) -> module
      _ -> nil
    end
  end

  # Render the Erlang logger msg tuple to a binary.
  # Logger produces three forms:
  # - {:string, iodata}        (most common from Elixir Logger)
  # - {format, args}           (Erlang :io_lib format strings)
  # - {:report, map_or_kv}     (structured logs)
  defp render_message({:string, iodata}) do
    iodata |> IO.iodata_to_binary() |> strip_ansi() |> truncate(2_000)
  rescue
    _ -> "<unrenderable string>"
  end

  defp render_message({:report, report}) do
    inspect(report, limit: 50, printable_limit: 500) |> truncate(2_000)
  rescue
    _ -> "<unrenderable report>"
  end

  defp render_message({format, args}) when is_list(format) or is_binary(format) do
    :io_lib.format(format, args)
    |> IO.iodata_to_binary()
    |> strip_ansi()
    |> truncate(2_000)
  rescue
    _ -> "<unrenderable format>"
  end

  defp render_message(other), do: inspect(other, limit: 50) |> truncate(2_000)

  # Strip ANSI escape sequences (colors, cursor moves, etc) from a rendered
  # message. Loggers like Ecto.Adapters.SQL emit pre-colorized output that
  # looks fine in a terminal but renders as literal garbage in HTML.
  @ansi_escape_regex ~r/\e\[[0-9;]*[A-Za-z]/
  defp strip_ansi(binary) do
    Regex.replace(@ansi_escape_regex, binary, "")
  end

  defp truncate(binary, max_length) when byte_size(binary) <= max_length, do: binary

  # Codepoint-aware slice so we never split a multi-byte UTF-8 sequence in
  # half and produce an invalid tail. `String.slice/2` may return slightly
  # fewer than max_length bytes for multi-byte runs — that's fine.
  defp truncate(binary, max_length), do: String.slice(binary, 0, max_length) <> "..."

  # Keep a small allowlist of scalar metadata. Drops pids, refs, huge structs.
  @allowed_meta_keys [:component, :mfa, :file, :line, :request_id, :crash_reason]

  defp prune_metadata(meta) do
    meta
    |> Map.take(@allowed_meta_keys)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, key, prune_value(key, value))
    end)
  end

  defp prune_value(:mfa, {module, fun, arity}) when is_atom(module) and is_atom(fun) do
    "#{inspect(module)}.#{fun}/#{arity}"
  end

  defp prune_value(:crash_reason, {reason, _stacktrace}) do
    inspect(reason, limit: 5, printable_limit: 200)
  end

  defp prune_value(_key, value)
       when is_binary(value) or is_number(value) or is_atom(value),
       do: value

  defp prune_value(_key, value), do: inspect(value, limit: 5, printable_limit: 100)
end
