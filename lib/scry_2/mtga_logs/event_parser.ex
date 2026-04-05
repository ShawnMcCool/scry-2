defmodule Scry2.MtgaLogs.EventParser do
  @moduledoc """
  Pure function module that splits MTGA log output into discrete events.

  ## Input shape

  MTGA's `Player.log` contains a mixture of Unity engine logs and
  structured event blocks tagged by the `UnityCrossThreadLogger`. The
  structured blocks look roughly like this:

  ```
  [UnityCrossThreadLogger]==> EventMatchCreated 4/5/2026 7:12:03 PM
  {
    "matchId": "abc-123",
    "opponentScreenName": "Opponent#12345",
    ...
  }
  ```

  Some events use a slightly different header format (e.g. `<==` for
  incoming data). The parser treats any non-JSON preamble as decoration
  and focuses on the first `{` after an event-type marker.

  ## Scope

  This first implementation is **intentionally generic**. It extracts
  type + JSON payload + timestamp from the dominant header format and
  leaves the raw JSON intact for downstream consumers. Domain-specific
  parsers (match ingester, draft ingester) read the `raw_json` field
  directly and interpret it however they need.

  Real log fixtures should be added under `test/fixtures/mtga_logs/`
  as we encounter new event shapes. See ADR-010: never delete parser
  tests — fix the parser.

  ## Purity

  No GenServer, no database, no file I/O. Input: raw text chunk +
  source metadata. Output: list of `%Scry2.MtgaLogs.Event{}` structs.
  """

  alias Scry2.MtgaLogs.Event

  @header_regex ~r/\[UnityCrossThreadLogger\][^\S\n]*(?:==>|<==)?\s*(?<type>[A-Za-z_][A-Za-z0-9_\.]*)(?:\s+(?<ts>\d{1,2}\/\d{1,2}\/\d{2,4}\s+\d{1,2}:\d{2}:\d{2}(?:\s*(?:AM|PM))?))?/

  @doc """
  Parses a chunk of log text starting at `base_offset` from `source_file`.

  Returns a list of `%Event{}` structs, one per successfully extracted
  event block. Lines that don't look like structured events are silently
  skipped — Unity engine logs, stack traces, etc.

  The `base_offset` should be the byte offset within `source_file` where
  this chunk starts; it's added to each event's own position within the
  chunk to produce the stable `file_offset` value.
  """
  @spec parse_chunk(binary(), String.t(), non_neg_integer()) :: [Event.t()]
  def parse_chunk(chunk, source_file, base_offset)
      when is_binary(chunk) and is_binary(source_file) and is_integer(base_offset) do
    chunk
    |> find_event_starts()
    |> Enum.flat_map(fn {header_offset, header_line, remainder} ->
      case extract_event(header_line, remainder, source_file, base_offset + header_offset) do
        {:ok, event} -> [event]
        :skip -> []
      end
    end)
  end

  # Scans for lines that look like event headers and returns tuples of
  # `{relative_offset, header_line, text_after_header}`.
  defp find_event_starts(chunk) do
    do_scan(chunk, 0, [])
  end

  defp do_scan("", _offset, acc), do: Enum.reverse(acc)

  defp do_scan(chunk, offset, acc) do
    case :binary.match(chunk, "[UnityCrossThreadLogger]") do
      :nomatch ->
        Enum.reverse(acc)

      {pos, _len} ->
        header_offset = offset + pos
        {_skipped, tail} = String.split_at(chunk, pos)

        {header_line, remainder} =
          case :binary.match(tail, "\n") do
            {nl_pos, _} ->
              {String.slice(tail, 0, nl_pos),
               binary_part(tail, nl_pos + 1, byte_size(tail) - nl_pos - 1)}

            :nomatch ->
              {tail, ""}
          end

        acc = [{header_offset, header_line, remainder} | acc]
        new_offset = header_offset + byte_size(header_line) + 1
        do_scan(remainder, new_offset, acc)
    end
  end

  defp extract_event(header_line, remainder, source_file, file_offset) do
    case Regex.named_captures(@header_regex, header_line) do
      %{"type" => type} when is_binary(type) and type != "" ->
        timestamp = Map.get(Regex.named_captures(@header_regex, header_line) || %{}, "ts")

        case grab_json_block(remainder) do
          {:ok, json_string} ->
            {:ok,
             %Event{
               type: type,
               mtga_timestamp: parse_timestamp(timestamp),
               payload: decode_json(json_string),
               raw_json: json_string,
               file_offset: file_offset,
               source_file: source_file
             }}

          :none ->
            :skip
        end

      _ ->
        :skip
    end
  end

  # Grabs a balanced JSON object starting at the first `{` in `text`.
  # Returns `{:ok, json_string}` or `:none` if no balanced object is
  # found. Handles nested braces and string escapes.
  defp grab_json_block(text) do
    case :binary.match(text, "{") do
      :nomatch ->
        :none

      {start, _} ->
        rest = binary_part(text, start, byte_size(text) - start)

        case scan_json(rest, 0, 0, false, false) do
          {:ok, length} -> {:ok, binary_part(rest, 0, length)}
          :none -> :none
        end
    end
  end

  # Depth-tracking JSON-object scanner.
  # Arguments: remaining text, current position, brace depth, in_string?, escaped?
  defp scan_json(<<>>, _pos, _depth, _in_string, _escaped), do: :none

  defp scan_json(<<"{"::utf8, rest::binary>>, pos, depth, false, _) do
    scan_json(rest, pos + 1, depth + 1, false, false)
  end

  defp scan_json(<<"}"::utf8, _rest::binary>>, pos, 1, false, _) do
    {:ok, pos + 1}
  end

  defp scan_json(<<"}"::utf8, rest::binary>>, pos, depth, false, _) do
    scan_json(rest, pos + 1, depth - 1, false, false)
  end

  defp scan_json(<<"\""::utf8, rest::binary>>, pos, depth, in_string, escaped) do
    cond do
      escaped -> scan_json(rest, pos + 1, depth, in_string, false)
      in_string -> scan_json(rest, pos + 1, depth, false, false)
      true -> scan_json(rest, pos + 1, depth, true, false)
    end
  end

  defp scan_json(<<"\\"::utf8, rest::binary>>, pos, depth, true, _) do
    scan_json(rest, pos + 1, depth, true, true)
  end

  defp scan_json(<<_byte::utf8, rest::binary>>, pos, depth, in_string, _) do
    scan_json(rest, pos + 1, depth, in_string, false)
  end

  defp scan_json(<<_byte, rest::binary>>, pos, depth, in_string, _) do
    scan_json(rest, pos + 1, depth, in_string, false)
  end

  defp decode_json(json_string) do
    case Jason.decode(json_string) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  # Best-effort timestamp parser. MTGA uses "M/D/YYYY h:MM:SS AM/PM" in
  # local time. Returns nil on any failure — the raw_json retains the
  # original data.
  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(""), do: nil

  defp parse_timestamp(string) when is_binary(string) do
    # For now just leave as nil — real timestamp parsing needs real log
    # samples to verify timezone handling. The raw_json contains enough
    # for downstream parsers to reconstruct time context.
    _ = string
    nil
  end
end
