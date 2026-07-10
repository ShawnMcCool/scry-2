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

  test "declares its provenance name" do
    assert MtgoSource.source_name() == "mtgo"
  end

  test "fetches standard event links from the landing page and parses each" do
    decks = MtgoSource.fetch(req_options: [plug: {Req.Test, MtgoSource}], max_events: 5)

    assert decks != []
    assert Enum.all?(decks, &(&1.source_url =~ "standard-challenge"))
  end

  test "skips non-standard events" do
    decks = MtgoSource.fetch(req_options: [plug: {Req.Test, MtgoSource}], max_events: 5)
    refute Enum.any?(decks, &(&1.source_url =~ "vintage"))
  end

  test "declares standard as its only browsable format" do
    assert MtgoSource.formats() == ["standard"]
  end

  describe "list_events/2" do
    test "parses landing-page links into events with name, date, and url" do
      assert {:ok, [event]} =
               MtgoSource.list_events("standard", req_options: [plug: {Req.Test, MtgoSource}])

      assert event.name == "Standard Challenge 32"
      assert event.date == ~D[2026-06-08]
      assert event.url == "https://www.mtgo.com/decklist/standard-challenge-32-2026-06-0812843830"
    end

    test "excludes events of other formats" do
      {:ok, events} =
        MtgoSource.list_events("standard", req_options: [plug: {Req.Test, MtgoSource}])

      refute Enum.any?(events, &(&1.url =~ "vintage"))
    end

    test "returns an error when the landing page is unreachable" do
      Req.Test.stub(MtgoSource, fn conn -> Plug.Conn.resp(conn, 503, "down") end)

      assert {:error, _reason} =
               MtgoSource.list_events("standard",
                 req_options: [plug: {Req.Test, MtgoSource}, retry: false]
               )
    end
  end

  describe "parse_event_link/2" do
    test "splits slug into humanized name, date, and full url" do
      assert %{name: "Standard Challenge 32", date: ~D[2026-06-27], url: url} =
               MtgoSource.parse_event_link(
                 "/decklist/standard-challenge-32-2026-06-2712845670",
                 "standard"
               )

      assert url == "https://www.mtgo.com/decklist/standard-challenge-32-2026-06-2712845670"
    end

    test "falls back to a dateless event when the slug has no date suffix" do
      assert %{name: "Standard League", date: nil} =
               MtgoSource.parse_event_link("/decklist/standard-league", "standard")
    end
  end

  describe "fetch_event/2" do
    test "returns the event's raw decks on success" do
      url = "https://www.mtgo.com/decklist/standard-challenge-32-2026-06-0812843830"

      assert {:ok, decks} =
               MtgoSource.fetch_event(url, req_options: [plug: {Req.Test, MtgoSource}])

      assert decks != []
      assert Enum.all?(decks, &(&1.source_url == url))
    end

    test "returns an error when the event page is unreachable" do
      Req.Test.stub(MtgoSource, fn conn -> Plug.Conn.resp(conn, 503, "down") end)

      assert {:error, _reason} =
               MtgoSource.fetch_event(
                 "https://www.mtgo.com/decklist/standard-challenge-32-2026-06-0812843830",
                 req_options: [plug: {Req.Test, MtgoSource}, retry: false]
               )
    end
  end
end
