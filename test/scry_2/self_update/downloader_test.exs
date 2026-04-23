defmodule Scry2.SelfUpdate.DownloaderTest do
  use ExUnit.Case, async: true
  alias Scry2.SelfUpdate.Downloader

  setup do
    dir = System.tmp_dir!() |> Path.join("downloader_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "parse_sha256sums/2" do
    test "returns checksum for filename" do
      sums = """
      abc123  scry_2-v0.15.0-linux-x86_64.tar.gz
      deadbeef  scry_2-v0.15.0-SHA256SUMS
      """

      assert {:ok, "abc123"} =
               Downloader.parse_sha256sums(sums, "scry_2-v0.15.0-linux-x86_64.tar.gz")
    end

    test "returns :not_found when absent" do
      assert :not_found = Downloader.parse_sha256sums("", "x.tar.gz")
    end

    test "downcases the checksum for consistent comparison" do
      assert {:ok, "abc123"} = Downloader.parse_sha256sums("ABC123  x\n", "x")
    end
  end

  describe "verify/2" do
    test "returns :ok for matching checksum", %{dir: dir} do
      path = Path.join(dir, "data")
      File.write!(path, "hello")
      # sha256("hello")
      expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
      assert :ok = Downloader.verify(path, expected)
    end

    test "returns {:error, :checksum_mismatch} otherwise", %{dir: dir} do
      path = Path.join(dir, "data")
      File.write!(path, "hello")

      assert {:error, :checksum_mismatch} =
               Downloader.verify(path, String.duplicate("0", 64))
    end
  end

  describe "run/2" do
    setup do
      Req.Test.stub(Scry2.SelfUpdate.Downloader, fn conn ->
        case conn.request_path do
          "/SHA256SUMS" ->
            sha =
              :crypto.hash(:sha256, "my release archive")
              |> Base.encode16(case: :lower)

            Plug.Conn.resp(conn, 200, "#{sha}  archive.tar.gz\n")

          "/archive.tar.gz" ->
            Plug.Conn.resp(conn, 200, "my release archive")

          "/bad-archive.tar.gz" ->
            Plug.Conn.resp(conn, 200, "tampered")

          "/bad-sums" ->
            Plug.Conn.resp(
              conn,
              200,
              "0000000000000000000000000000000000000000000000000000000000000000  bad-archive.tar.gz\n"
            )
        end
      end)

      :ok
    end

    test "downloads archive and sha256sums, verifies, returns path", %{dir: dir} do
      assert {:ok, %{archive_path: archive_path, sha256: sha}} =
               Downloader.run(
                 %{
                   archive_url: "http://x/archive.tar.gz",
                   archive_filename: "archive.tar.gz",
                   sha256sums_url: "http://x/SHA256SUMS",
                   dest_dir: dir
                 },
                 req_options: [plug: {Req.Test, Scry2.SelfUpdate.Downloader}]
               )

      assert File.exists?(archive_path)
      assert File.read!(archive_path) == "my release archive"
      assert sha == :crypto.hash(:sha256, "my release archive") |> Base.encode16(case: :lower)
    end

    test "returns checksum mismatch when archive is tampered", %{dir: dir} do
      assert {:error, :checksum_mismatch} =
               Downloader.run(
                 %{
                   archive_url: "http://x/bad-archive.tar.gz",
                   archive_filename: "bad-archive.tar.gz",
                   sha256sums_url: "http://x/bad-sums",
                   dest_dir: dir
                 },
                 req_options: [plug: {Req.Test, Scry2.SelfUpdate.Downloader}]
               )
    end
  end

  describe "size cap enforcement" do
    setup do
      # Stub returns a tarball larger than the test cap and a SHA that
      # would match if the body ever made it through.
      Req.Test.stub(Scry2.SelfUpdate.Downloader, fn conn ->
        case conn.request_path do
          "/SHA256SUMS" ->
            sha = String.duplicate("0", 64)
            Plug.Conn.resp(conn, 200, "#{sha}  big.tar.gz\n")

          "/big-with-content-length.tar.gz" ->
            # Server advertises a huge body via Content-Length; pre-flight
            # check should abort before any disk writes happen.
            big = :crypto.strong_rand_bytes(4096)

            conn
            |> Plug.Conn.put_resp_header("content-length", "999999999")
            |> Plug.Conn.resp(200, big)

          "/big-no-content-length.tar.gz" ->
            # No Content-Length — observed-bytes counter is the only cap.
            big = :crypto.strong_rand_bytes(4096)
            Plug.Conn.resp(conn, 200, big)
        end
      end)

      :ok
    end

    test "rejects download when Content-Length exceeds max_bytes", %{dir: dir} do
      assert {:error, :too_large} =
               Downloader.run(
                 %{
                   archive_url: "http://x/big-with-content-length.tar.gz",
                   archive_filename: "big.tar.gz",
                   sha256sums_url: "http://x/SHA256SUMS",
                   dest_dir: dir
                 },
                 req_options: [plug: {Req.Test, Scry2.SelfUpdate.Downloader}],
                 max_bytes: 1024
               )

      # No partial file left behind on disk.
      refute File.exists?(Path.join(dir, "big.tar.gz"))
    end

    test "rejects download when streamed bytes exceed max_bytes (no Content-Length)", %{dir: dir} do
      assert {:error, :too_large} =
               Downloader.run(
                 %{
                   archive_url: "http://x/big-no-content-length.tar.gz",
                   archive_filename: "big.tar.gz",
                   sha256sums_url: "http://x/SHA256SUMS",
                   dest_dir: dir
                 },
                 req_options: [plug: {Req.Test, Scry2.SelfUpdate.Downloader}],
                 max_bytes: 1024
               )

      refute File.exists?(Path.join(dir, "big.tar.gz"))
    end
  end

  describe "progress reporting" do
    test "calls progress_fn with final size on success", %{dir: dir} do
      Req.Test.stub(Scry2.SelfUpdate.Downloader, fn conn ->
        case conn.request_path do
          "/SHA256SUMS" ->
            body = "my body"

            sha =
              :crypto.hash(:sha256, body)
              |> Base.encode16(case: :lower)

            Plug.Conn.resp(conn, 200, "#{sha}  body.tar.gz\n")

          "/body.tar.gz" ->
            body = "my body"

            conn
            |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(body)))
            |> Plug.Conn.resp(200, body)
        end
      end)

      test_pid = self()

      progress_fn = fn downloaded, total ->
        send(test_pid, {:progress, downloaded, total})
        :ok
      end

      assert {:ok, _} =
               Downloader.run(
                 %{
                   archive_url: "http://x/body.tar.gz",
                   archive_filename: "body.tar.gz",
                   sha256sums_url: "http://x/SHA256SUMS",
                   dest_dir: dir
                 },
                 req_options: [plug: {Req.Test, Scry2.SelfUpdate.Downloader}],
                 progress_fn: progress_fn
               )

      # At least one progress tick reached the final size.
      assert_receive {:progress, _, _}
      bytes = byte_size("my body")
      assert_received_progress_with_total(bytes)
    end
  end

  defp assert_received_progress_with_total(expected_total) do
    received_messages =
      Stream.repeatedly(fn -> :foo end)
      |> Enum.reduce_while([], fn _, acc ->
        receive do
          {:progress, downloaded, total} -> {:cont, [{downloaded, total} | acc]}
        after
          0 -> {:halt, acc}
        end
      end)

    assert Enum.any?(received_messages, fn {_d, t} -> t == expected_total end),
           "expected at least one progress tick with total=#{expected_total}, got: #{inspect(received_messages)}"
  end
end
