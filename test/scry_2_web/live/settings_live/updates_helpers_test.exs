defmodule Scry2Web.SettingsLive.UpdatesHelpersTest do
  use ExUnit.Case, async: true
  alias Scry2Web.SettingsLive.UpdatesHelpers

  describe "summarize/3" do
    test ":up_to_date when versions match" do
      release = %{tag: "v0.14.0", version: "0.14.0", published_at: nil, html_url: "", body: ""}
      assert %{status: :up_to_date} = UpdatesHelpers.summarize({:ok, release}, "0.14.0", nil)
    end

    test ":update_available with new version" do
      release = %{tag: "v0.15.0", version: "0.15.0", published_at: nil, html_url: "", body: ""}

      assert %{status: :update_available, version: "0.15.0"} =
               UpdatesHelpers.summarize({:ok, release}, "0.14.0", nil)
    end

    test "passes through applying phase" do
      release = %{tag: "v0.15.0", version: "0.15.0", published_at: nil, html_url: "", body: ""}

      assert %{applying: :downloading} =
               UpdatesHelpers.summarize({:ok, release}, "0.14.0", :downloading)
    end

    test ":no_data when cache empty" do
      assert %{status: :no_data} = UpdatesHelpers.summarize(:none, "0.14.0", nil)
    end
  end

  describe "phase_label/1" do
    test "known phases" do
      assert UpdatesHelpers.phase_label(:preparing) == "Preparing"
      assert UpdatesHelpers.phase_label(:downloading) == "Downloading"
      assert UpdatesHelpers.phase_label(:extracting) == "Extracting"
      assert UpdatesHelpers.phase_label(:handing_off) == "Installing"
      assert UpdatesHelpers.phase_label(:done) == "Complete"
      assert UpdatesHelpers.phase_label(:failed) == "Failed"
    end

    test "unknown / idle is empty" do
      assert UpdatesHelpers.phase_label(:idle) == ""
      assert UpdatesHelpers.phase_label(nil) == ""
    end
  end
end
