defmodule Scry2.Decks.MtgaClipboardParser do
  @moduledoc """
  Parses MTGA clipboard-import text into card references. The inverse of
  `Scry2.Decks.MtgaClipboardFormat`.

      Deck
      4 Lightning Bolt (M21) 162

      Sideboard
      2 Negate (ZNR) 56

  Returns `%{main: [ref], sideboard: [ref]}` where each ref is
  `%{name, set_code, collector_number, count}` (set_code/collector_number
  may be nil for name-only lines). Lines that don't match a card pattern
  are skipped — resolution happens later, against the card DB.

  Name-only matching is lenient: a malformed full line with broken parens
  (e.g. `"4 Lightning Bolt (M21 162"`) falls through to the name-only
  pattern and yields a ref whose `name` is the whole remaining string with
  nil set_code/collector_number, rather than being skipped. Downstream
  resolution simply won't match it, so it's harmless.

  Pure function — no DB, no side effects.
  """

  @type ref :: %{
          name: String.t(),
          set_code: String.t() | nil,
          collector_number: String.t() | nil,
          count: pos_integer()
        }

  # "<count> <name> (<SET>) <collector>"  e.g. "4 Lightning Bolt (M21) 162"
  @full ~r/^\s*(\d+)\s+(.+?)\s+\(([^)]+)\)\s+(\S+)\s*$/
  # "<count> <name>"  e.g. "7 Mountain"
  @name_only ~r/^\s*(\d+)\s+(.+?)\s*$/

  @spec parse(String.t()) :: %{main: [ref()], sideboard: [ref()]}
  def parse(text) when is_binary(text) do
    {main, side, _section} =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], [], :main}, &reduce_line/2)

    %{main: Enum.reverse(main), sideboard: Enum.reverse(side)}
  end

  defp reduce_line(line, {main, side, section}) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> {main, side, section}
      header?(trimmed, "deck") -> {main, side, :main}
      header?(trimmed, "sideboard") -> {main, side, :sideboard}
      true -> add_ref(parse_line(trimmed), main, side, section)
    end
  end

  defp header?(line, word), do: String.downcase(line) == word

  defp add_ref(nil, main, side, section), do: {main, side, section}
  defp add_ref(ref, main, side, :main), do: {[ref | main], side, :main}
  defp add_ref(ref, main, side, :sideboard), do: {main, [ref | side], :sideboard}

  defp parse_line(line) do
    cond do
      captures = Regex.run(@full, line) ->
        [_, count, name, set_code, collector_number] = captures
        build_ref(name, set_code, collector_number, count)

      captures = Regex.run(@name_only, line) ->
        [_, count, name] = captures
        build_ref(name, nil, nil, count)

      true ->
        nil
    end
  end

  defp build_ref(name, set_code, collector_number, count) do
    %{
      name: String.trim(name),
      set_code: set_code && String.upcase(String.trim(set_code)),
      collector_number: collector_number && String.trim(collector_number),
      count: String.to_integer(count)
    }
  end
end
