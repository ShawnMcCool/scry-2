defmodule Scry2.NetDecking.Sources.MtgoSource do
  @moduledoc """
  Fetches current decklists from mtgo.com for Standard, Modern, Pioneer, and
  Pauper. The landing page lists event links (`/decklist/standard-challenge-…`,
  `/decklist/modern-league-…`, etc.); each event page server-renders
  `window.MTGO.decklists.data`, parsed by `Scry2.NetDecking.Sources.MtgoExtract`.

  Browsable (import browser): `formats/0` declares
  `["Standard", "Modern", "Pioneer", "Pauper"]`; `list_events/2` scrapes the
  landing page into `%{name, date, url}` events (name + date parsed from the
  link slug — the landing page carries nothing richer); `fetch_event/2` pulls
  one event's decklists by URL, stamping each with the format parsed from the
  event URL's slug (`format_from_url/1`).

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

  @formats ["Standard", "Modern", "Pioneer", "Pauper"]
  @format_by_slug %{
    "standard" => "Standard",
    "modern" => "Modern",
    "pioneer" => "Pioneer",
    "pauper" => "Pauper"
  }

  @impl true
  def source_name, do: "mtgo"

  @impl true
  def formats, do: @formats

  @impl true
  def fetch, do: fetch([])

  @spec fetch(keyword()) :: [Scry2.NetDecking.Source.raw_deck()]
  def fetch(opts) do
    req_options = Keyword.get(opts, :req_options, [])
    max_events = Keyword.get(opts, :max_events, @default_max_events)

    Enum.flat_map(@formats, &fetch_format(&1, req_options, max_events))
  end

  defp fetch_format(format, req_options, max_events) do
    case list_events(format, req_options: req_options) do
      {:ok, events} ->
        events
        |> Enum.take(max_events)
        |> Enum.flat_map(fn event ->
          case fetch_event(event.url, req_options: req_options) do
            {:ok, raw_decks} ->
              raw_decks

            {:error, reason} ->
              Log.warning(:importer, "mtgo event #{event.url} failed: #{inspect(reason)}")
              []
          end
        end)

      {:error, reason} ->
        Log.warning(:importer, "mtgo landing fetch failed (#{format}): #{inspect(reason)}")
        []
    end
  end

  @impl true
  def list_events(format), do: list_events(format, [])

  @spec list_events(String.t(), keyword()) ::
          {:ok, [Scry2.NetDecking.Source.event()]} | {:error, term()}
  def list_events(format, opts) do
    req_options = Keyword.get(opts, :req_options, [])
    slug = String.downcase(format)

    with {:ok, landing} <- get("#{@base}/decklists", req_options) do
      events =
        ~r{/decklist/#{slug}-[a-z0-9-]+}
        |> Regex.scan(landing)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.map(&parse_event_link(&1, slug))

      {:ok, events}
    end
  end

  @impl true
  def fetch_event(url), do: fetch_event(url, [])

  @spec fetch_event(String.t(), keyword()) ::
          {:ok, [Scry2.NetDecking.Source.raw_deck()]} | {:error, term()}
  def fetch_event(url, opts) do
    req_options = Keyword.get(opts, :req_options, [])
    format = format_from_url(url)

    with {:ok, html} <- get(url, req_options) do
      raw_decks =
        html
        |> MtgoExtract.raw_decks(url)
        |> Enum.map(&Map.put(&1, :format, format))

      {:ok, raw_decks}
    end
  end

  @doc """
  The Titlecase display format parsed from an MTGO decklist event URL's
  slug prefix (`.../decklist/modern-challenge-...` → `"Modern"`), or
  `nil` for a format this source doesn't declare (e.g. vintage).
  """
  @spec format_from_url(String.t()) :: String.t() | nil
  def format_from_url(url) do
    case Regex.run(~r{/decklist/([a-z]+)-}, url) do
      [_, slug] -> Map.get(@format_by_slug, slug)
      nil -> nil
    end
  end

  @doc """
  Pure: one landing-page link path → an event. Slugs end in the event date
  fused to a numeric event id (`…-2026-06-2712845670`); the leading words
  humanize into the event name (`standard-challenge-32` → "Standard
  Challenge 32"). Slugs without the date suffix yield `date: nil`.
  """
  @spec parse_event_link(String.t(), String.t()) :: Scry2.NetDecking.Source.event()
  def parse_event_link("/decklist/" <> slug = path, _format) do
    case Regex.run(~r/^([a-z0-9-]+?)-(\d{4})-(\d{2})-(\d{2})\d+$/, slug) do
      [_, name_slug, year, month, day] ->
        %{name: humanize(name_slug), date: to_date(year, month, day), url: @base <> path}

      nil ->
        %{name: humanize(slug), date: nil, url: @base <> path}
    end
  end

  defp humanize(slug) do
    slug
    |> String.split("-")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp to_date(year, month, day) do
    case Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
      {:ok, date} -> date
      {:error, _} -> nil
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
