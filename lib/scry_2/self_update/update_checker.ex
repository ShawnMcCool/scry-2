defmodule Scry2.SelfUpdate.UpdateChecker do
  @moduledoc """
  GitHub Releases fetch + tag validation + classification, with a 1-hour
  `:persistent_term` cache.

  **Security posture:**
    - Tags are validated against a strict semver regex before any interpolation.
    - Download URLs are built from a fixed template, never from API response
      fields.
    - Callers that round-trip through `classify/2` work with tags that have
      already been validated.
  """

  @cache_key {__MODULE__, :latest}
  @cache_ttl_ms :timer.hours(1)

  @tag_regex ~r/^v\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$/

  @github_owner "shawnmccool"
  @github_repo "scry_2"
  @api_url "https://api.github.com/repos/#{@github_owner}/#{@github_repo}/releases/latest"
  @download_base "https://github.com/#{@github_owner}/#{@github_repo}/releases/download"

  @type classification :: :update_available | :up_to_date | :ahead_of_release | :invalid

  @type release :: %{
          required(:tag) => String.t(),
          required(:version) => String.t(),
          required(:published_at) => String.t() | nil,
          required(:html_url) => String.t(),
          required(:body) => String.t()
        }

  # ---- Pure helpers ----

  @spec validate_tag(any()) :: {:ok, String.t()} | {:error, :invalid_tag}
  def validate_tag(tag) when is_binary(tag) do
    if Regex.match?(@tag_regex, tag), do: {:ok, tag}, else: {:error, :invalid_tag}
  end

  def validate_tag(_), do: {:error, :invalid_tag}

  @type os_type :: {:unix, atom()} | {:win32, atom()}

  @spec archive_name(String.t(), os_type()) :: String.t()
  def archive_name(tag, {:unix, :linux}), do: "scry_2-#{tag}-linux-x86_64.tar.gz"
  def archive_name(tag, {:unix, :darwin}), do: "scry_2-#{tag}-macos-x86_64.tar.gz"
  def archive_name(tag, {:win32, _}), do: "scry_2-#{tag}-windows-x86_64.zip"

  @spec sha256sums_name(String.t(), os_type()) :: String.t()
  def sha256sums_name(tag, {:unix, :linux}),
    do: "scry_2-#{tag}-linux-x86_64-SHA256SUMS"

  def sha256sums_name(tag, {:unix, :darwin}),
    do: "scry_2-#{tag}-macos-x86_64-SHA256SUMS"

  def sha256sums_name(tag, {:win32, _}),
    do: "scry_2-#{tag}-windows-x86_64-SHA256SUMS"

  @spec download_url(String.t(), String.t()) :: String.t()
  def download_url(tag, filename) do
    "#{@download_base}/#{tag}/#{filename}"
  end

  @doc """
  Classify a remote tag against the locally-running version using strict
  semver comparison. A pre-release suffix on the local version (e.g. a
  running dev build) naturally sorts below the same base release, so
  `classify("0.15.0", "0.15.0-dev")` returns `:update_available` — the
  release IS newer than the dev build.
  """
  @spec classify(String.t(), String.t()) :: classification()
  def classify(remote, local) when is_binary(remote) and is_binary(local) do
    with {:ok, r} <- parse_version(remote),
         {:ok, l} <- parse_version(local) do
      case Version.compare(r, l) do
        :gt -> :update_available
        :eq -> :up_to_date
        :lt -> :ahead_of_release
      end
    else
      _ -> :invalid
    end
  end

  def classify(_, _), do: :invalid

  defp parse_version("v" <> rest), do: parse_version(rest)
  defp parse_version(other) when is_binary(other), do: Version.parse(other)

  # ---- Cache ----

  @spec cached_latest_release() :: {:ok, release()} | :none
  def cached_latest_release do
    case :persistent_term.get(@cache_key, :none) do
      {release, stored_at_ms} ->
        if System.monotonic_time(:millisecond) - stored_at_ms < @cache_ttl_ms do
          {:ok, release}
        else
          :none
        end

      :none ->
        :none
    end
  end

  @spec put_cache(release()) :: :ok
  def put_cache(release) do
    :persistent_term.put(@cache_key, {release, System.monotonic_time(:millisecond)})
  end

  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  # ---- Fetch ----

  @doc """
  Fetch the latest GitHub release. Populates the cache on success.

  Options:
    - `:req_options` — passed through to `Req.get/2` (for `:plug` stubbing
      in tests)
  """
  @spec latest_release(keyword()) ::
          {:ok, release()}
          | {:error, :invalid_tag | {:rate_limited, integer() | nil} | term()}
  def latest_release(opts \\ []) do
    req_options = Keyword.get(opts, :req_options, [])

    request =
      [url: @api_url, receive_timeout: 10_000, retry: false]
      |> Keyword.merge(req_options)

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_response(body)

      {:ok, %Req.Response{status: status, headers: headers}}
      when status in 401..499 ->
        if rate_limited?(headers) do
          {:error, {:rate_limited, reset_epoch(headers)}}
        else
          {:error, {:http_status, status}}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp parse_response(body) when is_map(body) do
    with {:ok, tag} <- validate_tag(body["tag_name"]),
         "v" <> version <- tag do
      release = %{
        tag: tag,
        version: version,
        published_at: body["published_at"],
        html_url: body["html_url"] || "",
        body: (body["body"] || "") |> String.slice(0, 20_000)
      }

      put_cache(release)
      {:ok, release}
    end
  end

  defp parse_response(_), do: {:error, :invalid_response}

  defp rate_limited?(headers) do
    case header_value(headers, "x-ratelimit-remaining") do
      "0" -> true
      _ -> false
    end
  end

  defp reset_epoch(headers) do
    with value when is_binary(value) <- header_value(headers, "x-ratelimit-reset"),
         {int, ""} <- Integer.parse(value) do
      int
    else
      _ -> nil
    end
  end

  # Req 0.5 normalises response headers to a map of lowercase-string -> [value, ...].
  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end
