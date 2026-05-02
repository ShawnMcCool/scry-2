defmodule Scry2.Cards.BoosterCollationTest do
  use ExUnit.Case, async: true

  alias Scry2.Cards.BoosterCollation

  @fixture_path "test/fixtures/mtga_alt_booster_sample.json"

  describe "parse/1" do
    test "extracts collation_id → set_code mappings from ALT_Booster JSON" do
      json = File.read!(@fixture_path)
      mappings = BoosterCollation.parse(json)

      assert {100_060, "BLB"} in mappings
      assert {200_060, "BLB"} in mappings
    end

    test "follows language-extractor branches via en-US" do
      json = File.read!(@fixture_path)
      mappings = BoosterCollation.parse(json)

      assert {100_052, "DFT"} in mappings
    end

    test "deduplicates equivalent paths from list children" do
      json = File.read!(@fixture_path)
      mappings = BoosterCollation.parse(json)

      eoe_entries = Enum.filter(mappings, fn {cid, _} -> cid == 400_055 end)
      assert eoe_entries == [{400_055, "EOE"}]
    end

    test "returns empty list for malformed input" do
      assert BoosterCollation.parse("{}") == []
      assert BoosterCollation.parse(~s({"ALT_Booster.Logo": {}})) == []
    end
  end

  describe "set_code_from_path/1" do
    test "strips language suffix" do
      path = "Assets/Core/Art/Shared/Images/SetLogos/SetLogo_DFT_EN.png"
      assert BoosterCollation.set_code_from_path(path) == "DFT"
    end

    test "handles set codes without language suffix" do
      path = "Assets/Core/Art/Shared/Images/SetLogos/SetLogo_BLB.png"
      assert BoosterCollation.set_code_from_path(path) == "BLB"
    end

    test "handles longer set codes" do
      path = "Assets/Core/Art/Shared/Images/SetLogos/SetLogo_FDN_EN.png"
      assert BoosterCollation.set_code_from_path(path) == "FDN"
    end

    test "returns nil for unmatched paths" do
      assert BoosterCollation.set_code_from_path("Assets/foo/bar.png") == nil
      assert BoosterCollation.set_code_from_path(nil) == nil
    end
  end

  describe "find_json_path/1" do
    @tag :tmp_dir
    test "finds the ALT_Booster_*.mtga file in a directory", %{tmp_dir: dir} do
      fake = Path.join(dir, "ALT_Booster_abc123.mtga")
      File.write!(fake, "{}")

      assert BoosterCollation.find_json_path(dir) == fake
    end

    @tag :tmp_dir
    test "returns nil when no file matches", %{tmp_dir: dir} do
      assert BoosterCollation.find_json_path(dir) == nil
    end
  end
end
