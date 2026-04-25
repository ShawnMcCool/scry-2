defmodule Scry2.SelfUpdate.Stager do
  @moduledoc """
  Extracts a downloaded archive into a staging directory, **validating
  every entry before touching the filesystem**.

  Rejected entries:
    - Absolute paths (`/...`, Windows drive-letter roots)
    - Parent-directory traversal (`..` segment anywhere in the path)
    - Symlinks (tarballs only; zip has no symlink type in the subset we use)
    - Device / FIFO / socket nodes

  This module is security-critical. Any change here must preserve the
  "validate first, extract second" invariant — an attacker must never be
  able to write a byte outside the staging root.

  ## Required-file check

  After extraction, every path in the `:required` opt is checked for
  existence under the extracted root. A truncated or malformed release
  fails fast with `{:error, {:missing_required, [...]}}` — preferable to
  handing off to an installer binary that won't know how to migrate.
  """

  @max_cumulative_bytes 1_024 * 1024 * 1024

  @spec extract_tar(Path.t(), Path.t(), keyword()) ::
          {:ok, Path.t()}
          | {:error,
             :path_traversal | :symlink | :oversized | {:missing_required, [String.t()]} | term()}
  def extract_tar(archive, dest_dir, opts \\ []) do
    required = Keyword.get(opts, :required, [])
    archive_c = String.to_charlist(archive)

    with {:ok, entries} <- :erl_tar.table(archive_c, [:compressed, :verbose]),
         :ok <- validate_tar_entries(entries) do
      File.mkdir_p!(dest_dir)
      root = Path.join(dest_dir, "extracted")
      File.mkdir_p!(root)

      with :ok <-
             (case :erl_tar.extract(archive_c, [:compressed, {:cwd, String.to_charlist(root)}]) do
                :ok -> :ok
                {:error, reason} -> {:error, reason}
              end) do
        effective = strip_single_wrapper(root)

        case check_required(effective, required) do
          :ok -> {:ok, effective}
          err -> err
        end
      end
    end
  end

  @spec extract_zip(Path.t(), Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, {:missing_required, [String.t()]} | term()}
  def extract_zip(archive, dest_dir, opts \\ []) do
    required = Keyword.get(opts, :required, [])
    archive_c = String.to_charlist(archive)

    with {:ok, entries} <- :zip.list_dir(archive_c),
         :ok <- validate_zip_entries(entries) do
      File.mkdir_p!(dest_dir)
      root = Path.join(dest_dir, "extracted")
      File.mkdir_p!(root)

      with {:ok, _files} <- :zip.extract(archive_c, [{:cwd, String.to_charlist(root)}]) do
        effective = strip_single_wrapper(root)

        case check_required(effective, required) do
          :ok -> {:ok, effective}
          err -> err
        end
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Real release archives wrap their contents under a single
  # `scry_2-vX.Y.Z-<platform>/` directory (`scripts/release` builds
  # the tarball that way; the bootstrap installer matches the
  # convention with `tar --strip-components=1`). When the extracted
  # root contains exactly that single wrapper, descend into it so
  # the rest of the SelfUpdate pipeline (required-file check,
  # Handoff path construction) operates on the actual release root.
  #
  # The check is intentionally narrow — only a directory whose name
  # starts with `scry_2-` qualifies. A bare `bin/` directory at the
  # top level (the legacy / synthetic-test layout) is left alone.
  @spec strip_single_wrapper(Path.t()) :: Path.t()
  defp strip_single_wrapper(root) do
    case File.ls(root) do
      {:ok, [single]} ->
        candidate = Path.join(root, single)

        if String.starts_with?(single, "scry_2-") and File.dir?(candidate) do
          candidate
        else
          root
        end

      _ ->
        root
    end
  end

  @spec check_required(Path.t(), [String.t()]) ::
          :ok | {:error, {:missing_required, [String.t()]}}
  def check_required(_root, []), do: :ok

  def check_required(root, required) when is_list(required) do
    missing = Enum.reject(required, fn rel -> root |> Path.join(rel) |> File.exists?() end)

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_required, missing}}
    end
  end

  @spec safe_entry?(String.t()) :: boolean()
  def safe_entry?(path) when is_binary(path) do
    cond do
      path == "" -> false
      String.starts_with?(path, "/") -> false
      ".." in Path.split(path) -> false
      true -> true
    end
  end

  defp validate_tar_entries(entries) do
    Enum.reduce_while(entries, {:ok, 0}, fn entry, {:ok, cumulative} ->
      case classify_tar_entry(entry) do
        {:ok, name, size} ->
          cond do
            not safe_entry?(name) ->
              {:halt, {:error, :path_traversal}}

            cumulative + size > @max_cumulative_bytes ->
              {:halt, {:error, :oversized}}

            true ->
              {:cont, {:ok, cumulative + size}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # `:erl_tar.table/2` with `:verbose` may return tuples of varying arity
  # depending on the tar format. We handle the shapes we care about and
  # reject anything else.
  defp classify_tar_entry({name_c, :symlink, _, _, _, _, _}) when is_list(name_c),
    do: {:error, :symlink}

  defp classify_tar_entry({name_c, type, size, _, _, _, _})
       when type in [:regular, :directory] and is_list(name_c) do
    {:ok, to_string(name_c), size}
  end

  defp classify_tar_entry({name_c, :other, _size, _, _, _, _}) when is_list(name_c),
    do: {:error, :unsupported_entry_type}

  defp classify_tar_entry(name_c) when is_list(name_c) do
    {:ok, to_string(name_c), 0}
  end

  defp classify_tar_entry(other), do: {:error, {:unknown_entry, other}}

  defp validate_zip_entries(entries) do
    Enum.reduce_while(entries, :ok, fn
      {:zip_comment, _}, acc ->
        {:cont, acc}

      {:zip_file, name_c, _info, _comment, _offset, _comp_size}, acc ->
        name = to_string(name_c)
        if safe_entry?(name), do: {:cont, acc}, else: {:halt, {:error, :path_traversal}}

      _, acc ->
        {:cont, acc}
    end)
  end
end
