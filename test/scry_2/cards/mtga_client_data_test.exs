defmodule Scry2.Cards.MtgaClientDataTest do
  use Scry2.DataCase, async: true

  alias Scry2.Cards
  alias Scry2.Cards.MtgaClientData

  describe "run/1 with the real MTGA database" do
    @tag :external
    test "imports cards from the MTGA client database" do
      assert {:ok, %{imported: count}} = MtgaClientData.run()
      assert count > 20_000
      assert Cards.mtga_card_count() > 20_000

      gnarlid = Cards.get_mtga_card(93_937)
      assert gnarlid.name == "Gnarlid Colony"
      assert gnarlid.expansion_code == "FDN"
      assert gnarlid.collector_number == "224"

      forest = Cards.get_mtga_card(100_652)
      assert forest.name == "Forest"
      assert forest.expansion_code == "TMT"
    end
  end

  describe "find_database_path/1" do
    test "finds the Raw_CardDatabase file in a directory" do
      dir = Path.join(System.tmp_dir!(), "mtga_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      fake_db = Path.join(dir, "Raw_CardDatabase_abc123.mtga")
      File.write!(fake_db, "fake")

      assert MtgaClientData.find_database_path(dir) == fake_db

      File.rm_rf!(dir)
    end

    test "returns nil when no database file exists" do
      dir = Path.join(System.tmp_dir!(), "empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      assert MtgaClientData.find_database_path(dir) == nil
      File.rm_rf!(dir)
    end
  end
end
