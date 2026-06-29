defmodule Scry2.NetDecking.Sources.MtgoSourceTest do
  use ExUnit.Case, async: true

  alias Scry2.NetDecking.Sources.MtgoSource

  @deck_html File.read!(
               Path.expand("../../../fixtures/netdecking/mtgo_standard_challenge.html", __DIR__)
             )

  setup do
    Req.Test.stub(MtgoSource, fn conn ->
      cond do
        conn.request_path == "/decklists" ->
          Plug.Conn.resp(
            conn,
            200,
            ~s|<a href="/decklist/standard-challenge-32-2026-06-0812843830">x</a>| <>
              ~s|<a href="/decklist/vintage-league-2026-06-2910887">y</a>|
          )

        String.starts_with?(conn.request_path, "/decklist/standard-") ->
          Plug.Conn.resp(conn, 200, @deck_html)

        true ->
          Plug.Conn.resp(conn, 404, "no")
      end
    end)

    :ok
  end

  test "fetches standard event links from the landing page and parses each" do
    decks = MtgoSource.fetch(req_options: [plug: {Req.Test, MtgoSource}], max_events: 5)

    assert decks != []
    assert Enum.all?(decks, &(&1.source_name == "mtgo"))
    assert Enum.all?(decks, &(&1.source_url =~ "standard-challenge"))
  end

  test "skips non-standard events" do
    decks = MtgoSource.fetch(req_options: [plug: {Req.Test, MtgoSource}], max_events: 5)
    refute Enum.any?(decks, &(&1.source_url =~ "vintage"))
  end
end
