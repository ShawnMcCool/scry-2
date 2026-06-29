defmodule Scry2.NetDecking.Sources.MtgoSource do
  @moduledoc """
  Fetches current-Standard decklists from mtgo.com. The landing page lists
  event links (`/decklist/standard-challenge-…`, `/decklist/standard-league-…`);
  each event page server-renders `window.MTGO.decklists.data`, parsed by
  `Scry2.NetDecking.Sources.MtgoExtract`.

  First-party Wizards/Daybreak source — no Cloudflare, honest User-Agent, never
  a browser-UA spoof. Politeness: events fetched per run are capped; HTTP is
  isolated behind a `req_options` opt so tests stub it with `Req.Test`. A failed
  landing or event fetch logs and yields fewer (or no) decks — it never raises.
  """
  @behaviour Scry2.NetDecking.Source

  alias Scry2.NetDecking.Sources.MtgoExtract

  require Scry2.Log, as: Log

  @base "https://www.mtgo.com"
  @user_agent "scry2/#{Mix.Project.config()[:version]} (+https://github.com/ShawnMcCool/scry-2)"
  @default_max_events 8

  @impl true
  def fetch, do: fetch([])

  @spec fetch(keyword()) :: [Scry2.NetDecking.Source.raw_deck()]
  def fetch(opts) do
    req_options = Keyword.get(opts, :req_options, [])
    max_events = Keyword.get(opts, :max_events, @default_max_events)

    case get("#{@base}/decklists", req_options) do
      {:ok, landing} ->
        landing
        |> standard_links()
        |> Enum.take(max_events)
        |> Enum.flat_map(fn path -> fetch_event(path, req_options) end)

      {:error, reason} ->
        Log.warning(:importer, "mtgo landing fetch failed: #{inspect(reason)}")
        []
    end
  end

  defp standard_links(html) do
    ~r{/decklist/standard-[a-z0-9-]+}
    |> Regex.scan(html)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp fetch_event(path, req_options) do
    url = @base <> path

    case get(url, req_options) do
      {:ok, html} ->
        MtgoExtract.raw_decks(html, url)

      {:error, reason} ->
        Log.warning(:importer, "mtgo event #{path} failed: #{inspect(reason)}")
        []
    end
  end

  defp get(url, req_options) do
    options =
      [url: url, user_agent: @user_agent, max_retries: 2, receive_timeout: 30_000]
      |> Keyword.merge(req_options)

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, to_string(body)}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
