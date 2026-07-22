defmodule Scry2.NetDecking.Sources.LocalJsonSource do
  @moduledoc """
  Reads an out-of-band JSON meta-feed file into `raw_deck` maps. The canonical,
  zero-legal-risk NetDecking source: the file is authored outside the app, so
  no third-party ToS/Cloudflare/HTML-stability concern touches the running
  instance, and `decklist_text` is already MTGA clipboard format (`(SET)
  collector`) — the cleanest arena_id resolution path.

  File shape:

      {"decks": [{"name", "archetype"?, "format"?, "source_url"?, "decklist_text"}]}

  A missing or malformed file yields `[]` — the scheduler degrades gracefully
  rather than crashing.
  """
  @behaviour Scry2.NetDecking.Source

  alias Scry2.Config

  require Scry2.Log, as: Log

  @impl true
  def source_name, do: "local"

  # Not browsable: the feed is a single out-of-band file, not an event catalog.
  @impl true
  def formats, do: []

  @impl true
  def fetch, do: fetch(path: Config.get(:netdecking_local_feed_path))

  @spec fetch(keyword()) :: [Scry2.NetDecking.Source.raw_deck()]
  def fetch(opts) do
    path = Keyword.get(opts, :path)

    with true <- is_binary(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"decks" => decks}} when is_list(decks) <- JSON.decode(body) do
      Enum.map(decks, &to_raw_deck/1)
    else
      other ->
        Log.warning(
          :importer,
          "local netdeck feed unavailable (#{inspect(path)}): #{inspect(other)}"
        )

        []
    end
  end

  defp to_raw_deck(%{"name" => name, "decklist_text" => text} = deck) do
    %{
      name: name,
      decklist_text: text,
      archetype: deck["archetype"],
      source_url: deck["source_url"]
    }
    |> put_format(deck["format"])
  end

  defp put_format(raw_deck, nil), do: raw_deck
  defp put_format(raw_deck, format), do: Map.put(raw_deck, :format, format)
end
