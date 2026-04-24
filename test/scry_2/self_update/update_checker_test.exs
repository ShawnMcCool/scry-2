defmodule Scry2.SelfUpdate.UpdateCheckerTest do
  use ExUnit.Case, async: true
  alias Scry2.SelfUpdate.UpdateChecker

  describe "validate_tag/1" do
    test "accepts v-prefixed semver" do
      assert {:ok, "v0.14.0"} = UpdateChecker.validate_tag("v0.14.0")
      assert {:ok, "v1.2.3"} = UpdateChecker.validate_tag("v1.2.3")
    end

    test "accepts pre-release suffix" do
      assert {:ok, "v0.14.0-rc.1"} = UpdateChecker.validate_tag("v0.14.0-rc.1")
    end

    test "rejects unprefixed semver" do
      assert {:error, :invalid_tag} = UpdateChecker.validate_tag("0.14.0")
    end

    test "rejects injection attempts" do
      assert {:error, :invalid_tag} = UpdateChecker.validate_tag("v0.14.0; rm -rf /")
      assert {:error, :invalid_tag} = UpdateChecker.validate_tag("../../../etc/passwd")
      assert {:error, :invalid_tag} = UpdateChecker.validate_tag("v0.14.0/../x")
    end

    test "rejects nil and empty" do
      assert {:error, :invalid_tag} = UpdateChecker.validate_tag(nil)
      assert {:error, :invalid_tag} = UpdateChecker.validate_tag("")
    end
  end

  describe "archive_name/2" do
    test "linux tarball" do
      assert UpdateChecker.archive_name("v0.14.0", {:unix, :linux}) ==
               "scry_2-v0.14.0-linux-x86_64.tar.gz"
    end

    test "macos tarball" do
      assert UpdateChecker.archive_name("v0.14.0", {:unix, :darwin}) ==
               "scry_2-v0.14.0-macos-x86_64.tar.gz"
    end

    test "windows zip" do
      assert UpdateChecker.archive_name("v0.14.0", {:win32, :nt}) ==
               "scry_2-v0.14.0-windows-x86_64.zip"
    end
  end

  describe "download_url/2" do
    test "builds URL from validated tag and archive" do
      assert UpdateChecker.download_url("v0.14.0", "scry_2-v0.14.0-linux-x86_64.tar.gz") ==
               "https://github.com/ShawnMcCool/scry-2/releases/download/v0.14.0/scry_2-v0.14.0-linux-x86_64.tar.gz"
    end
  end

  describe "classify/2" do
    test ":update_available when remote > local" do
      assert UpdateChecker.classify("0.15.0", "0.14.0") == :update_available
    end

    test ":up_to_date when equal" do
      assert UpdateChecker.classify("0.14.0", "0.14.0") == :up_to_date
    end

    test ":ahead_of_release when local > remote" do
      # Running a newer prod release than the latest remote tag.
      assert UpdateChecker.classify("0.14.0", "0.15.0") == :ahead_of_release
    end

    test "a prod release supersedes an equivalent local dev build" do
      # Per semver, 0.15.0-dev < 0.15.0, so a cached release of 0.15.0
      # is considered an update when running 0.15.0-dev locally.
      assert UpdateChecker.classify("0.15.0", "0.15.0-dev") == :update_available
    end

    test "strips leading v" do
      assert UpdateChecker.classify("v0.15.0", "v0.14.0") == :update_available
    end

    test ":invalid when either is garbage" do
      assert UpdateChecker.classify("not-semver", "0.14.0") == :invalid
    end
  end

  describe "latest_release/1" do
    setup do
      UpdateChecker.clear_cache()
      on_exit(fn -> UpdateChecker.clear_cache() end)
      :ok
    end

    test "parses a successful API response into a release map" do
      Req.Test.stub(UpdateChecker, fn conn ->
        assert conn.request_path == "/repos/ShawnMcCool/scry-2/releases/latest"

        Req.Test.json(conn, %{
          "tag_name" => "v0.15.0",
          "published_at" => "2026-04-20T12:00:00Z",
          "html_url" => "https://github.com/ShawnMcCool/scry-2/releases/tag/v0.15.0",
          "body" => "Release notes"
        })
      end)

      assert {:ok, release} =
               UpdateChecker.latest_release(req_options: [plug: {Req.Test, UpdateChecker}])

      assert release.tag == "v0.15.0"
      assert release.version == "0.15.0"
      assert release.published_at == "2026-04-20T12:00:00Z"
      assert release.html_url =~ "v0.15.0"
    end

    test "rejects a response with an invalid tag" do
      Req.Test.stub(UpdateChecker, fn conn ->
        Req.Test.json(conn, %{
          "tag_name" => "latest-build-123",
          "published_at" => nil,
          "html_url" => "",
          "body" => ""
        })
      end)

      assert {:error, :invalid_tag} =
               UpdateChecker.latest_release(req_options: [plug: {Req.Test, UpdateChecker}])
    end

    test "surfaces rate-limit errors with reset DateTime" do
      reset_epoch = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()

      Req.Test.stub(UpdateChecker, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", Integer.to_string(reset_epoch))
        |> Plug.Conn.resp(403, ~s|{"message":"rate limit"}|)
      end)

      assert {:error, {:rate_limited, %DateTime{} = reset_at}} =
               UpdateChecker.latest_release(req_options: [plug: {Req.Test, UpdateChecker}])

      assert abs(DateTime.diff(reset_at, DateTime.from_unix!(reset_epoch))) <= 2
    end

    test "rate-limit reset is nil when the reset header is absent" do
      Req.Test.stub(UpdateChecker, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.resp(403, ~s|{"message":"rate limit"}|)
      end)

      assert {:error, {:rate_limited, nil}} =
               UpdateChecker.latest_release(req_options: [plug: {Req.Test, UpdateChecker}])
    end

    test "non-rate-limit 403 falls through to {:http_status, 403}" do
      Req.Test.stub(UpdateChecker, fn conn ->
        Plug.Conn.resp(conn, 403, "forbidden")
      end)

      assert {:error, {:http_status, 403}} =
               UpdateChecker.latest_release(req_options: [plug: {Req.Test, UpdateChecker}])
    end

    test "replaces an html_url pointing at an unexpected host" do
      Req.Test.stub(UpdateChecker, fn conn ->
        Req.Test.json(conn, %{
          "tag_name" => "v1.0.0",
          "published_at" => "2026-04-20T12:00:00Z",
          "html_url" => "https://evil.example.com/fake",
          "body" => ""
        })
      end)

      assert {:ok, release} =
               UpdateChecker.latest_release(req_options: [plug: {Req.Test, UpdateChecker}])

      assert release.html_url ==
               "https://github.com/ShawnMcCool/scry-2/releases/tag/v1.0.0"
    end

    test "replaces a missing html_url with a tag-based URL" do
      Req.Test.stub(UpdateChecker, fn conn ->
        Req.Test.json(conn, %{
          "tag_name" => "v1.0.0",
          "published_at" => nil,
          "body" => ""
        })
      end)

      assert {:ok, release} =
               UpdateChecker.latest_release(req_options: [plug: {Req.Test, UpdateChecker}])

      assert release.html_url ==
               "https://github.com/ShawnMcCool/scry-2/releases/tag/v1.0.0"
    end

    test "populates the cache on success" do
      Req.Test.stub(UpdateChecker, fn conn ->
        Req.Test.json(conn, %{
          "tag_name" => "v0.99.0",
          "published_at" => nil,
          "html_url" => "http://example",
          "body" => ""
        })
      end)

      assert {:ok, _release} =
               UpdateChecker.latest_release(req_options: [plug: {Req.Test, UpdateChecker}])

      assert {:ok, %{tag: "v0.99.0"}} = UpdateChecker.cached_latest_release()
    end
  end
end
