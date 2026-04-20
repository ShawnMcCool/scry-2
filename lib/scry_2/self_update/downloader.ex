defmodule Scry2.SelfUpdate.Downloader do
  @moduledoc """
  Downloads an update archive and its SHA256SUMS, then verifies the
  archive against the declared checksum using constant-time comparison.

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

    with {:ok, sums_body} <- fetch_text(args.sha256sums_url, req_options),
         {:ok, expected_sha} <- parse_sha256sums(sums_body, args.archive_filename),
         {:ok, archive_path} <-
           download_to_file(
             args.archive_url,
             Path.join(args.dest_dir, args.archive_filename),
             req_options,
             progress_fn
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

  defp download_to_file(url, path, req_options, progress_fn) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)

    file_stream = File.stream!(path, 65_536)

    request =
      [url: url, receive_timeout: 120_000, retry: false, into: file_stream]
      |> Keyword.merge(req_options)

    case Req.get(request) do
      {:ok, %Req.Response{status: 200}} ->
        case File.stat(path) do
          {:ok, %File.Stat{size: size}} when size > @max_archive_bytes ->
            File.rm(path)
            {:error, :archive_too_large}

          {:ok, %File.Stat{size: size}} ->
            progress_fn.(size, size)
            {:ok, path}

          other ->
            other
        end

      {:ok, %Req.Response{status: status}} ->
        File.rm(path)
        {:error, {:http_status, status}}

      {:error, reason} ->
        File.rm(path)
        {:error, {:transport, reason}}
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
