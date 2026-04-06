defmodule Scry2.MtgaLogIngestion.ExtractEventsFromLog do
  @moduledoc """
  Pipeline stage 04 — extract `%Scry2.MtgaLogIngestion.Event{}` structs from raw
  Player.log text.

  ## Contract

  | | |
  |---|---|
  | **Input**  | Binary chunk of log text + source metadata (`source_file`, `base_offset`) |
  | **Output** | List of `%Event{type, mtga_timestamp, payload, raw_json, file_offset, source_file}` |
  | **Nature** | Pure — no DB, no GenServer, no file I/O |
  | **Called from** | `Scry2.MtgaLogIngestion.Watcher.drain_file/1` (stage 03 → 04) |
  | **Hands off to** | `Scry2.MtgaLogIngestion.insert_event!/1` (stage 04 → 05) |

  Non-event lines (Unity engine logs, stack traces) are silently
  skipped. Malformed event blocks are silently skipped — the raw JSON
  preserves every byte, so downstream tooling can reparse when the
  parser improves.

  ## The two header formats in Player.log

  MTGA writes two distinct header shapes. This parser recognizes both
  via plain function-head pattern matching on the binary prefix (see
  `parse_header/1`).

  **Format A — API request/response** (lobby, deck management, rank):

      [UnityCrossThreadLogger]==> EventJoin {"id":"...","request":"..."}
      [UnityCrossThreadLogger]<== EventJoin(uuid)

  Type appears immediately after `==>` or `<==`. No timestamp in the
  header; the payload may carry its own.

  **Format B — match/game event** (match lifecycle, GRE stream):

      [UnityCrossThreadLogger]4/5/2026 11:47:09 AM: Match to USER_ID: MatchGameRoomStateChangedEvent

  The header carries a 12-hour local timestamp (`M/D/YYYY H:MM:SS AM/PM`)
  and the event type is at the end of the line. These events carry all
  real match/game activity nested inside the JSON payload below.

  ## Why not regex or parser combinators?

  For two flat header shapes with no recursion or backtracking, Elixir's
  pattern matching on binary prefixes is the cleanest tool. Regex turns
  into a tangled mess at the first format extension; parser combinators
  (NimbleParsec, etc.) are overkill for something this regular. If the
  grammar ever grows (nested MTGA protocol, GRE sub-messages), revisit.

  ## Tests and fixtures (ADR-010)

  Real fixtures only — every parser test case is backed by a real MTGA
  log block in `test/fixtures/mtga_logs/`. Never synthetic. Never
  delete or weaken a regression test. Fix the parser, not the test.
  """

  alias Scry2.MtgaLogIngestion.Event

  @doc """
  Parses a chunk of log text starting at `base_offset` from `source_file`.

  Returns a list of `%Event{}` structs, one per successfully extracted
  event block. The `base_offset` is added to each event's position
  within the chunk to produce the stable `file_offset` value.
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

  # Finds every `[UnityCrossThreadLogger]` occurrence in the chunk and
  # returns tuples of `{byte_offset, header_line, text_after_newline}`.
  # Uses pure binary operations — no grapheme-based slicing, no
  # recursion. `:binary.matches/2` does the heavy lifting in a single
  # O(n) pass.
  #
  # For each match position `pos`, the header_line is the bytes from
  # `pos` up to (but not including) the next `\n`. The remainder is
  # the bytes after that `\n`, up to the end of the chunk — which
  # includes all subsequent events. `grab_json_block/1` is responsible
  # for extracting only the JSON body that belongs to this event.
  defp find_event_starts(chunk) do
    chunk_size = byte_size(chunk)

    :binary.matches(chunk, "[UnityCrossThreadLogger]")
    |> Enum.map(fn {pos, _len} ->
      tail_size = chunk_size - pos
      tail = binary_part(chunk, pos, tail_size)

      case :binary.match(tail, "\n") do
        {nl_pos, _} ->
          header_line = binary_part(tail, 0, nl_pos)
          remainder_size = tail_size - nl_pos - 1
          remainder = binary_part(tail, nl_pos + 1, remainder_size)
          {pos, header_line, remainder}

        :nomatch ->
          {pos, tail, ""}
      end
    end)
  end

  defp extract_event(header_line, remainder, source_file, file_offset) do
    with {:ok, type, timestamp} <- parse_header(header_line),
         {:ok, json_string} <- find_json_body(header_line, remainder) do
      {:ok,
       %Event{
         type: type,
         mtga_timestamp: timestamp,
         payload: decode_json(json_string),
         raw_json: json_string,
         file_offset: file_offset,
         source_file: source_file
       }}
    else
      _ -> :skip
    end
  end

  # Real MTGA logs put the JSON body in one of two places depending on
  # format:
  #
  # * **Format A inline** — the entire event fits on one line:
  #   `[UnityCrossThreadLogger]==> EventJoin {"id":"..."}`. The body
  #   lives inside `header_line` itself.
  #
  # * **Format B multiline** — the header is on its own line and the
  #   JSON body follows on the next line(s). The body lives in
  #   `remainder`.
  #
  # Try header_line first (it wins for Format A), fall back to remainder
  # (for Format B and the legacy synthetic Format A test fixtures where
  # the JSON is on a separate line).
  defp find_json_body(header_line, remainder) do
    case grab_json_block(header_line) do
      {:ok, _json} = ok -> ok
      :none -> grab_json_block(remainder)
    end
  end

  # ── Header parsing ────────────────────────────────────────────────────
  #
  # Two formats, matched in order of specificity. Format A's `==>`/`<==`
  # prefixes are matched first; bare-prefix Format B catches everything
  # else that starts with the logger tag. Anything without the logger
  # tag never reaches here — `find_event_starts/1` filters those.

  # Format A (API request): [UnityCrossThreadLogger]==> EventType {json}
  defp parse_header("[UnityCrossThreadLogger]==> " <> rest) do
    case take_identifier(rest) do
      "" -> :skip
      type -> {:ok, type, nil}
    end
  end

  # Format A (API response): [UnityCrossThreadLogger]<== EventType(uuid)
  defp parse_header("[UnityCrossThreadLogger]<== " <> rest) do
    case take_identifier(rest) do
      "" -> :skip
      type -> {:ok, type, nil}
    end
  end

  # Format B (match/game event): [UnityCrossThreadLogger]M/D/YYYY H:MM:SS AM/PM: <direction>: EventType
  defp parse_header("[UnityCrossThreadLogger]" <> rest) do
    case String.split(rest, ": ", parts: 3) do
      [timestamp_str, _direction, type_str] ->
        case take_identifier(type_str) do
          "" -> :skip
          type -> {:ok, type, parse_timestamp(timestamp_str)}
        end

      _ ->
        :skip
    end
  end

  # Anything else (defensive — should never happen given find_event_starts).
  defp parse_header(_), do: :skip

  # Take a leading identifier: starts with [A-Za-z_], continues with
  # [A-Za-z0-9_.], terminated by any other character or end of string.
  # Returns "" if the first character isn't a valid identifier start.
  defp take_identifier(<<c, _::binary>> = string)
       when c in ?A..?Z or c in ?a..?z or c == ?_ do
    scan_identifier(string, 1)
  end

  defp take_identifier(_), do: ""

  defp scan_identifier(string, pos) do
    case string do
      <<_::binary-size(pos), c, _::binary>>
      when c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c == ?_ or c == ?. ->
        scan_identifier(string, pos + 1)

      <<head::binary-size(pos), _::binary>> ->
        head
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

  # Parses "M/D/YYYY H:MM:SS AM/PM" (12-hour clock) into a `%DateTime{}`.
  # Returns nil on any parse failure — the raw_json preserves the
  # original bytes so downstream tooling can reparse.
  #
  # MTGA writes timestamps in local time with no zone annotation. We
  # tag them as UTC for now and accept the drift. Fixing this properly
  # requires either sniffing the OS timezone or a config entry — see
  # `TODO.md` > "Match ingestion follow-ups" > timezone handling.
  defp parse_timestamp(""), do: nil

  defp parse_timestamp(string) when is_binary(string) do
    with [date_str, time_str, ampm] <- String.split(string, " ", parts: 3),
         {:ok, {month, day, year}} <- parse_date_parts(date_str),
         {:ok, {hour12, minute, second}} <- parse_time_parts(time_str),
         {:ok, hour24} <- convert_to_24h(hour12, ampm),
         {:ok, date} <- Date.new(expand_year(year), month, day),
         {:ok, time} <- Time.new(hour24, minute, second),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      datetime
    else
      _ -> nil
    end
  end

  defp parse_date_parts(date_str) do
    with [m, d, y] <- String.split(date_str, "/"),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d),
         {year, ""} <- Integer.parse(y) do
      {:ok, {month, day, year}}
    else
      _ -> :error
    end
  end

  defp parse_time_parts(time_str) do
    with [h, mi, s] <- String.split(time_str, ":"),
         {hour, ""} <- Integer.parse(h),
         {minute, ""} <- Integer.parse(mi),
         {second, ""} <- Integer.parse(s) do
      {:ok, {hour, minute, second}}
    else
      _ -> :error
    end
  end

  defp convert_to_24h(12, "AM"), do: {:ok, 0}
  defp convert_to_24h(12, "PM"), do: {:ok, 12}
  defp convert_to_24h(hour, "AM") when hour in 0..11, do: {:ok, hour}
  defp convert_to_24h(hour, "PM") when hour in 1..11, do: {:ok, hour + 12}
  defp convert_to_24h(_, _), do: :error

  # MTGA uses 2- or 4-digit years. Normalize to 4 digits.
  defp expand_year(year) when year >= 100, do: year
  defp expand_year(year) when year >= 0, do: 2000 + year
end
