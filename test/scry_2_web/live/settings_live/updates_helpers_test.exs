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

    test "body is propagated from the release into the summary" do
      release = %{
        tag: "v0.15.0",
        version: "0.15.0",
        published_at: nil,
        html_url: "",
        body: "## Fixed\n\n- something cool"
      }

      assert %{body: "## Fixed\n\n- something cool"} =
               UpdatesHelpers.summarize({:ok, release}, "0.14.0", nil)
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

  describe "format_error/2" do
    test "rate-limited with reset DateTime shows minutes remaining" do
      now = ~U[2026-04-24 12:00:00Z]
      reset = DateTime.add(now, 1500, :second)

      message = UpdatesHelpers.format_error({:rate_limited, reset}, now)
      assert message =~ "rate-limited"
      assert message =~ "25m"
    end

    test "rate-limited with reset under a minute shows seconds" do
      now = ~U[2026-04-24 12:00:00Z]
      reset = DateTime.add(now, 30, :second)

      assert UpdatesHelpers.format_error({:rate_limited, reset}, now) =~ "30s"
    end

    test "rate-limited with reset over an hour shows hours and minutes" do
      now = ~U[2026-04-24 12:00:00Z]
      reset = DateTime.add(now, 3 * 3600 + 12 * 60, :second)

      message = UpdatesHelpers.format_error({:rate_limited, reset}, now)
      assert message =~ "3h"
      assert message =~ "12m"
    end

    test "rate-limited without reset still produces a message" do
      assert UpdatesHelpers.format_error({:rate_limited, nil}, DateTime.utc_now()) =~
               "rate-limited"
    end

    test "http_status surfaces the status code" do
      assert UpdatesHelpers.format_error({:http_status, 503}, DateTime.utc_now()) =~ "503"
    end

    test "transport surfaces the underlying reason" do
      message = UpdatesHelpers.format_error({:transport, :econnrefused}, DateTime.utc_now())
      assert message =~ "Network"
      assert message =~ "econnrefused"
    end

    test "invalid_response is human-readable" do
      assert UpdatesHelpers.format_error(:invalid_response, DateTime.utc_now()) =~ "malformed"
    end

    test "nil returns nil" do
      assert is_nil(UpdatesHelpers.format_error(nil, DateTime.utc_now()))
    end

    test "unrecognised error falls through to inspect" do
      message = UpdatesHelpers.format_error({:weird, 1, 2}, DateTime.utc_now())
      assert message =~ "Update check failed"
    end
  end

  describe "summarize/4 with last_error" do
    test "last_error is included in the summary" do
      summary = UpdatesHelpers.summarize(:none, "0.14.0", nil, "rate-limited")
      assert summary.last_error == "rate-limited"
    end

    test "last_error defaults to nil with the 3-arity form" do
      summary = UpdatesHelpers.summarize(:none, "0.14.0", nil)
      assert summary.last_error == nil
    end
  end
end
