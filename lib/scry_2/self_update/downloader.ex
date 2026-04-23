defmodule Scry2.SelfUpdate.Downloader do
  @moduledoc """
  Downloads an update archive and its SHA256SUMS, then verifies the
  archive against the declared checksum using constant-time comparison.

  ## Size enforcement

    * `Content-Length` is pre-flight-checked against `@max_archive_bytes`
      on the first chunk. A lying server that advertises a huge body is
      aborted before any bytes hit disk.
    * Streaming bytes are also counted, so a server that omits
      `Content-Length` (or lies about it small) is still capped by
      observed size.

  Progress is reported via the caller-supplied `:progress_fn` option,
  which is invoked with `(bytes_downloaded, total_bytes)`.
  """

  @max_archive_bytes 500 * 1024 * 1024

  @type run_args :: %{
          required(:archive_url) => String.t(),
          required(:archive_filename) => String.t(),
          required(:sha256sums_url) => String.t(),
          required(:dest_dir) => Path.t()
        }

  @type run_result :: %{
          archive_path: Path.t(),
          sha256: String.t()
        }

  @spec run(run_args(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(%{} = args, opts \\ []) do
    req_options = Keyword.get(opts, :req_options, [])
    progress_fn = Keyword.get(opts, :progress_fn, fn _, _ -> :ok end)
    max_bytes = Keyword.get(opts, :max_bytes, @max_archive_bytes)

    with {:ok, sums_body} <- fetch_text(args.sha256sums_url, req_options),
         {:ok, expected_sha} <- parse_sha256sums(sums_body, args.archive_filename),
         {:ok, archive_path} <-
           download_to_file(
             args.archive_url,
             Path.join(args.dest_dir, args.archive_filename),
             req_options,
             progress_fn,
             max_bytes
           ),
         :ok <- verify(archive_path, expected_sha) do
      {:ok, %{archive_path: archive_path, sha256: expected_sha}}
    end
  end

  @spec parse_sha256sums(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def parse_sha256sums(body, filename) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.find_value(:not_found, fn line ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [sha, ^filename] -> {:ok, String.downcase(sha)}
        _ -> nil
      end
    end)
  end

  @spec verify(Path.t(), String.t()) :: :ok | {:error, :checksum_mismatch}
  def verify(path, expected_sha) when is_binary(expected_sha) do
    actual = hash_file(path)

    if Plug.Crypto.secure_compare(actual, String.downcase(expected_sha)) do
      :ok
    else
      {:error, :checksum_mismatch}
    end
  end

  defp fetch_text(url, req_options) do
    request = Keyword.merge([url: url, receive_timeout: 30_000, retry: false], req_options)

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp download_to_file(url, path, req_options, progress_fn, max_bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)

    file = File.open!(path, [:write, :binary])

    try do
      do_download(url, path, file, req_options, progress_fn, max_bytes)
    after
      File.close(file)
    end
  end

  # Streams the response body via Req's `:into` callback. The callback
  #   1. Pre-flight-checks Content-Length on the first chunk (rejects
  #      before disk I/O if the server's declared size exceeds the cap).
  #   2. Counts streamed bytes and halts mid-download if observed size
  #      exceeds the cap (handles servers that omit Content-Length or
  #      lie about it small).
  # State (bytes-so-far, last-reported-pct, header-checked) lives in
  # `resp.private` because the callback is invoked per chunk and Req
  # only threads `{req, resp}` between invocations.
  defp do_download(url, path, file, req_options, progress_fn, max_bytes) do
    progress_fn.(0, nil)

    into_fn = fn {:data, chunk}, {req, resp} ->
      state = Map.get(resp.private || %{}, :dl_state, %{bytes: 0, last_pct: -1})
      total = resp.headers |> header_value("content-length") |> parse_integer()

      cond do
        is_integer(total) and total > max_bytes ->
          {:halt, {req, mark_too_large(resp)}}

        state.bytes + byte_size(chunk) > max_bytes ->
          {:halt, {req, mark_too_large(resp)}}

        true ->
          :ok = IO.binwrite(file, chunk)
          new_bytes = state.bytes + byte_size(chunk)
          new_pct = maybe_report_progress(state, new_bytes, total, progress_fn)

          {:cont, {req, put_dl_state(resp, %{bytes: new_bytes, last_pct: new_pct})}}
      end
    end

    request =
      [url: url, receive_timeout: 120_000, retry: false, into: into_fn]
      |> Keyword.merge(req_options)

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, private: %{dl_state: %{too_large?: true}}}} ->
        File.rm(path)
        {:error, :too_large}

      {:ok, %Req.Response{status: 200, private: %{dl_state: %{bytes: bytes}}}} ->
        progress_fn.(bytes, bytes)
        {:ok, path}

      {:ok, %Req.Response{status: 200}} ->
        # Empty body — :into never fired. Treat as success with 0 bytes.
        progress_fn.(0, 0)
        {:ok, path}

      {:ok, %Req.Response{status: status}} ->
        File.rm(path)
        {:error, {:http_status, status}}

      {:error, reason} ->
        File.rm(path)
        {:error, {:transport, reason}}
    end
  end

  defp put_dl_state(resp, state) do
    private = Map.put(resp.private || %{}, :dl_state, state)
    %{resp | private: private}
  end

  defp mark_too_large(resp) do
    state = Map.get(resp.private || %{}, :dl_state, %{bytes: 0, last_pct: -1})
    put_dl_state(resp, Map.put(state, :too_large?, true))
  end

  defp maybe_report_progress(state, new_bytes, total, progress_fn) do
    cond do
      is_integer(total) and total > 0 ->
        pct = div(new_bytes * 100, total)

        if pct > state.last_pct do
          progress_fn.(new_bytes, total)
          pct
        else
          state.last_pct
        end

      true ->
        state.last_pct
    end
  end

  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [v | _] when is_binary(v) -> v
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp header_value(_headers, _name), do: nil

  defp parse_integer(nil), do: nil

  defp parse_integer(text) when is_binary(text) do
    case Integer.parse(text) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp hash_file(path) do
    path
    |> File.stream!(64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
