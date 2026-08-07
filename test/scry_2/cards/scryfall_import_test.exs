defmodule Scry2.Cards.ScryfallImportTest do
  @moduledoc """
  End-to-end coverage of `Scry2.Cards.Scryfall.run/1` — catalog fetch,
  compressed download, decode, persist.

  This path had no test, which is how the bulk-data format change went
  unnoticed: Scryfall replaced `download_uri` (a plain JSON array) with
  `jsonl_download_uri` (gzip-compressed JSONL), the import began failing on
  every run, and because `PeriodicallyImportScryfallCards` discards cleanly
  the only symptom was card data quietly going stale.
  """
  use Scry2.DataCase, async: false

  @moduletag :capture_log

  alias Scry2.Cards
  alias Scry2.Cards.Scryfall

  @catalog_path "/bulk-data/default-cards"
  @download_path "/default-cards/default-cards-20260807.jsonl.gz"

  test "imports every card from the gzipped JSONL bulk file" do
    stub_bulk_data([
      card("aaaa-1", "Lightning Bolt", "lea", arena_id: 91_829, oracle_text: "Deal 3 damage."),
      card("aaaa-2", "Counterspell", "lea", arena_id: 91_830),
      card("aaaa-3", "Black Lotus", "lea")
    ])

    assert {:ok, %{persisted: 3}} =
             Scryfall.run(
               url: "https://api.scryfall.com" <> @catalog_path,
               req_options: [plug: {Req.Test, Scryfall}]
             )

    bolt = Cards.get_scryfall_by_arena_id(91_829)
    assert bolt.name == "Lightning Bolt"
    # upsert_scryfall_card!/1 normalises set codes to uppercase.
    assert bolt.set_code == "LEA"
    assert bolt.oracle_text == "Deal 3 damage."

    assert Cards.get_scryfall_by_arena_id(91_830).name == "Counterspell"
  end

  test "handles a final line with no trailing newline" do
    # JSONL producers are not required to terminate the last record, and a
    # naive split would silently drop that card.
    body = @download_path |> body_for([card("bbbb-1", "Shock", "m21", arena_id: 70_001)])
    stub(String.trim_trailing(body, "\n"))

    assert {:ok, %{persisted: 1}} =
             Scryfall.run(
               url: "https://api.scryfall.com" <> @catalog_path,
               req_options: [plug: {Req.Test, Scryfall}]
             )

    assert Cards.get_scryfall_by_arena_id(70_001).name == "Shock"
  end

  # The real bulk file is ~77 MB compressed and is read in 256 KB chunks, so
  # `:zlib.inflate/2` is called many times and returns deeply nested iodata.
  # A handful of cards fits in one chunk and comes back as a single flat
  # binary, which hides that — this payload is large enough to force both
  # multi-chunk inflation and lines that straddle a chunk boundary.
  test "decodes a payload spanning many inflate chunks" do
    cards =
      for index <- 1..4_000 do
        card("cccc-#{index}", "Padded Card #{index}", "tst",
          arena_id: 600_000 + index,
          oracle_text: String.duplicate("oracle text padding ", 30)
        )
      end

    stub_bulk_data(cards)

    assert {:ok, %{persisted: 4_000}} =
             Scryfall.run(
               url: "https://api.scryfall.com" <> @catalog_path,
               req_options: [plug: {Req.Test, Scryfall}]
             )

    assert Cards.get_scryfall_by_arena_id(600_001).name == "Padded Card 1"
    assert Cards.get_scryfall_by_arena_id(604_000).name == "Padded Card 4000"
  end

  test "reports a clear error when the catalog has no jsonl_download_uri" do
    Req.Test.stub(Scryfall, fn conn ->
      Req.Test.json(conn, %{"object" => "bulk_data", "description" => "no uri here"})
    end)

    assert {:error, {:missing_download_uri, %{"description" => "no uri here"}}} =
             Scryfall.run(
               url: "https://api.scryfall.com" <> @catalog_path,
               req_options: [plug: {Req.Test, Scryfall}]
             )
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp card(id, name, set, opts \\ []) do
    %{
      "object" => "card",
      "id" => id,
      "name" => name,
      "set" => set,
      "set_name" => String.upcase(set),
      "collector_number" => "1",
      "rarity" => "rare",
      "arena_id" => opts[:arena_id],
      "oracle_text" => opts[:oracle_text]
    }
  end

  defp body_for(_path, cards), do: Enum.map_join(cards, "", &(Jason.encode!(&1) <> "\n"))

  defp stub_bulk_data(cards), do: cards |> then(&body_for(@download_path, &1)) |> stub()

  defp stub(jsonl) do
    gzipped = :zlib.gzip(jsonl)

    Req.Test.stub(Scryfall, fn conn ->
      case conn.request_path do
        @catalog_path ->
          Req.Test.json(conn, %{
            "object" => "bulk_data",
            "type" => "default_cards",
            "jsonl_download_uri" => "https://data.scryfall.io" <> @download_path
          })

        @download_path ->
          conn
          |> Plug.Conn.put_resp_content_type("application/gzip")
          |> Plug.Conn.resp(200, gzipped)
      end
    end)
  end
end
