defmodule Scry2.Cards.Lands17ImporterTest do
  use Scry2.DataCase, async: true

  alias Scry2.Cards
  alias Scry2.Cards.Lands17Importer

  @sample_csv """
  id,expansion,name,rarity,color_identity,mana_value,types,is_booster
  1,LCI,Mountain,common,R,0,Basic Land — Mountain,true
  2,LCI,Lightning Bolt,common,R,1,Instant,true
  3,OTJ,Thunderhawk Gunship,rare,,5,Artifact — Vehicle,true
  """

  describe "parse_csv/1 (pure)" do
    test "parses a header row and yields per-row maps" do
      rows = Lands17Importer.parse_csv(@sample_csv)

      assert length(rows) == 3

      mountain = Enum.find(rows, &(&1["name"] == "Mountain"))
      assert mountain["id"] == "1"
      assert mountain["expansion"] == "LCI"
      assert mountain["color_identity"] == "R"
    end

    test "handles an empty input gracefully" do
      assert Lands17Importer.parse_csv("") == []
    end
  end

  describe "run/1 with a Req.Test stub" do
    setup do
      Req.Test.stub(Lands17Importer, fn conn ->
        Req.Test.text(conn, @sample_csv)
      end)

      :ok
    end

    test "imports rows into cards_cards and cards_sets" do
      assert {:ok, %{imported: 3}} =
               Lands17Importer.run(
                 url: "http://stub.test/cards.csv",
                 req_options: [plug: {Req.Test, Lands17Importer}]
               )

      assert Cards.count() == 3
      assert Cards.get_set_by_code("LCI").code == "LCI"
      assert Cards.get_set_by_code("OTJ").code == "OTJ"

      mountain = Cards.get_by_lands17_id(1)
      assert mountain.name == "Mountain"
      assert mountain.color_identity == "R"
      assert mountain.is_booster == true
    end

    test "re-running is idempotent (ADR-016)" do
      opts = [
        url: "http://stub.test/cards.csv",
        req_options: [plug: {Req.Test, Lands17Importer}]
      ]

      {:ok, %{imported: 3}} = Lands17Importer.run(opts)
      {:ok, %{imported: 3}} = Lands17Importer.run(opts)

      # Still only three rows — second run updates, doesn't duplicate.
      assert Cards.count() == 3
    end

    test "broadcasts cards_updates with the imported count" do
      Scry2.Topics.subscribe(Scry2.Topics.cards_updates())

      {:ok, _} =
        Lands17Importer.run(
          url: "http://stub.test/cards.csv",
          req_options: [plug: {Req.Test, Lands17Importer}]
        )

      assert_receive {:cards_refreshed, 3}
    end

    test "never overwrites an existing arena_id on re-import (ADR-014)" do
      # Simulate a Scryfall backfill that populated arena_id for card id=1.
      Lands17Importer.run(
        url: "http://stub.test/cards.csv",
        req_options: [plug: {Req.Test, Lands17Importer}]
      )

      mountain = Cards.get_by_lands17_id(1)
      {:ok, mountain} = mountain |> Ecto.Changeset.change(arena_id: 91_001) |> Repo.update()
      assert mountain.arena_id == 91_001

      # A fresh import should NOT clobber the existing arena_id.
      Lands17Importer.run(
        url: "http://stub.test/cards.csv",
        req_options: [plug: {Req.Test, Lands17Importer}]
      )

      assert Cards.get_by_lands17_id(1).arena_id == 91_001
    end
  end

  describe "run/1 error handling" do
    test "returns an error when no url is configured" do
      assert {:error, :no_url_configured} = Lands17Importer.run(url: nil, req_options: [])
    end

    test "returns an error on non-200 status" do
      Req.Test.stub(Lands17Importer, fn conn ->
        conn
        |> Plug.Conn.resp(500, "boom")
      end)

      # `retry: false` short-circuits Req's default exponential backoff
      # for 5xx responses — without it this test takes 7 seconds and
      # trips sandbox timeouts on parallel tests.
      assert {:error, {:http_status, 500}} =
               Lands17Importer.run(
                 url: "http://stub.test/cards.csv",
                 req_options: [plug: {Req.Test, Lands17Importer}, retry: false]
               )
    end
  end
end
