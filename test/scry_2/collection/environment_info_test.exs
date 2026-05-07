defmodule Scry2.Collection.EnvironmentInfoTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.EnvironmentInfo

  describe "parse_build_version/1" do
    test "extracts the build segment from a production front-door host" do
      assert EnvironmentInfo.parse_build_version(
               "frontdoor-mtga-production-2026-58-30-2.w2.mtgarena.com"
             ) == "2026-58-30-2"
    end

    test "handles arbitrary env names + region segments" do
      assert EnvironmentInfo.parse_build_version(
               "frontdoor-mtga-stage-2026-1-0-0.eu1.mtgarena.com"
             ) == "2026-1-0-0"
    end

    test "nil → nil" do
      assert EnvironmentInfo.parse_build_version(nil) == nil
    end

    test "non-matching host → nil (no exception)" do
      assert EnvironmentInfo.parse_build_version("api.platform.wizards.com") == nil
      assert EnvironmentInfo.parse_build_version("") == nil
      assert EnvironmentInfo.parse_build_version("frontdoor-mtga-foo") == nil
    end
  end

  describe "host_platform_label/1" do
    test "1 → \"Steam\"" do
      assert EnvironmentInfo.host_platform_label(1) == "Steam"
    end

    test "nil → nil" do
      assert EnvironmentInfo.host_platform_label(nil) == nil
    end

    test "unknown integer falls back to a labelled identifier" do
      assert EnvironmentInfo.host_platform_label(7) == "Platform 7"
      assert EnvironmentInfo.host_platform_label(0) == "Platform 0"
    end
  end
end
