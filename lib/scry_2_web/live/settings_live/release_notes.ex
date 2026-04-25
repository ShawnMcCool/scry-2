defmodule Scry2Web.SettingsLive.ReleaseNotes do
  @moduledoc """
  Minimal markdown renderer for the "What's new in vX.Y.Z" disclosure
  on the System page Updates card.

  The scope is deliberately narrow: we only parse the shapes our own
  release notes produce — `##`/`###` headings, `-` or `*` bullet
  lists, `**bold**`, and inline `` `code` ``. Everything else passes
  through as plain text.

  This avoids pulling in a full CommonMark dependency for a few hundred
  characters of well-controlled content. All output flows through HEEx's
  automatic escaping, so there is no HTML/markdown injection surface.

  ## Block shapes returned by `parse/1`

      {:heading, level, inline}
      {:paragraph, inline}
      {:list, [inline, ...]}

  ## Inline shapes

      {:text, binary}
      {:strong, inline}
      {:code, binary}
  """

  use Phoenix.Component

  @type inline :: [inline_node()]
  @type inline_node ::
          {:text, String.t()} | {:strong, inline()} | {:code, String.t()}

  @type block ::
          {:heading, 1..6, inline()}
          | {:paragraph, inline()}
          | {:list, [inline()]}

  attr :body, :string, default: ""
  attr :class, :string, default: nil

  @doc """
  Renders a parsed release-notes body.

  When `body` is blank, renders a gentle fallback note so the disclosure
  still looks intentional rather than empty.
  """
  def release_notes(assigns) do
    blocks = parse(assigns.body)
    assigns = assign(assigns, :blocks, blocks)

    ~H"""
    <div class={["space-y-3 text-base-content/80", @class]}>
      <p :if={@blocks == []} class="italic text-base-content/50">
        No release notes available for this version.
      </p>
      <.block :for={block <- @blocks} block={block} />
    </div>
    """
  end

  attr :block, :any, required: true

  defp block(%{block: {:heading, level, inline}} = assigns) do
    assigns = assign(assign(assigns, :inline, inline), :level, level)

    ~H"""
    <h4
      :if={@level >= 3}
      class="text-xs font-medium uppercase tracking-wider text-base-content/50 pt-1"
    >
      <.inline :for={node <- @inline} node={node} />
    </h4>
    <h3
      :if={@level == 2}
      class="text-sm font-semibold text-base-content pt-1"
    >
      <.inline :for={node <- @inline} node={node} />
    </h3>
    """
  end

  defp block(%{block: {:paragraph, inline}} = assigns) do
    assigns = assign(assigns, :inline, inline)

    ~H"""
    <p class="leading-relaxed">
      <.inline :for={node <- @inline} node={node} />
    </p>
    """
  end

  defp block(%{block: {:list, items}} = assigns) do
    assigns = assign(assigns, :items, items)

    ~H"""
    <ul class="space-y-1.5 pl-4 list-disc marker:text-base-content/40">
      <li :for={item <- @items} class="leading-relaxed">
        <.inline :for={node <- item} node={node} />
      </li>
    </ul>
    """
  end

  attr :node, :any, required: true

  defp inline(%{node: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"{@text}"
  end

  defp inline(%{node: {:strong, children}} = assigns) do
    assigns = assign(assigns, :children, children)

    ~H"""
    <strong class="font-semibold text-base-content">
      <.inline :for={child <- @children} node={child} />
    </strong>
    """
  end

  defp inline(%{node: {:code, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <code class="font-mono text-xs px-1 py-0.5 rounded bg-base-content/10 text-base-content">
      {@text}
    </code>
    """
  end

  @heading_re ~r/\A(\#{1,6})\s+(.+)\z/
  @bullet_re ~r/\A\s*[-*]\s+(.+)\z/
  @continuation_re ~r/\A\s{2,}\S/

  @doc "Parses a markdown body string into a list of block tuples."
  @spec parse(String.t() | nil) :: [block()]
  def parse(nil), do: []

  def parse(body) when is_binary(body) do
    body
    |> normalize_newlines()
    |> split_blocks()
    |> Enum.map(&parse_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_newlines(body) do
    body
    |> String.replace(~r/\r\n?/, "\n")
    |> String.trim()
  end

  defp split_blocks(text) do
    text
    |> String.split(~r/\n{2,}/, trim: true)
    |> Enum.map(&String.trim_trailing/1)
  end

  defp parse_block(text) do
    lines = String.split(text, "\n")

    cond do
      bullet_block?(lines) -> {:list, parse_list_items(lines)}
      match = Regex.run(@heading_re, String.trim(text)) -> heading_from_match(match)
      String.trim(text) == "" -> nil
      true -> {:paragraph, parse_inline(unwrap_paragraph(lines))}
    end
  end

  defp bullet_block?(lines), do: Enum.any?(lines, &Regex.match?(@bullet_re, &1))

  defp heading_from_match([_, hashes, body]) do
    {:heading, String.length(hashes), parse_inline(String.trim(body))}
  end

  defp unwrap_paragraph(lines) do
    Enum.map_join(lines, " ", &String.trim/1)
  end

  defp parse_list_items(lines) do
    lines
    |> Enum.reduce([], fn line, items ->
      cond do
        match = Regex.run(@bullet_re, line) ->
          [_, text] = match
          [text | items]

        Regex.match?(@continuation_re, line) and items != [] ->
          [current | rest] = items
          [current <> " " <> String.trim(line) | rest]

        items != [] and String.trim(line) != "" ->
          [current | rest] = items
          [current <> " " <> String.trim(line) | rest]

        true ->
          items
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&parse_inline/1)
  end

  @spec parse_inline(String.t()) :: inline()
  def parse_inline(text) when is_binary(text), do: scan_inline(text, "", [])

  defp scan_inline("", buf, acc), do: finalize(buf, acc)

  defp scan_inline("**" <> rest, buf, acc) do
    case split_on(rest, "**") do
      {:ok, inner, tail} ->
        scan_inline(tail, "", [{:strong, parse_inline(inner)} | flush(buf, acc)])

      :miss ->
        scan_inline(rest, buf <> "**", acc)
    end
  end

  defp scan_inline("`" <> rest, buf, acc) do
    case split_on(rest, "`") do
      {:ok, inner, tail} -> scan_inline(tail, "", [{:code, inner} | flush(buf, acc)])
      :miss -> scan_inline(rest, buf <> "`", acc)
    end
  end

  defp scan_inline(<<ch::utf8, rest::binary>>, buf, acc) do
    scan_inline(rest, buf <> <<ch::utf8>>, acc)
  end

  defp flush("", acc), do: acc
  defp flush(buf, acc), do: [{:text, buf} | acc]

  defp finalize(buf, acc), do: Enum.reverse(flush(buf, acc))

  defp split_on(text, marker) do
    case :binary.match(text, marker) do
      {start, len} ->
        before = :binary.part(text, 0, start)
        after_ = :binary.part(text, start + len, byte_size(text) - start - len)
        {:ok, before, after_}

      :nomatch ->
        :miss
    end
  end
end
