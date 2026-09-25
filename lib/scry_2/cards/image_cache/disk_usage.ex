defmodule Scry2.Cards.ImageCache.DiskUsage do
  @moduledoc """
  How much disk the card image cache occupies, maintained incrementally.

  ## Why this is not recomputed on read

  The /cards Data Sources panel reports the image cache's file count and
  total bytes. Deriving those on read means one `File.stat/1` per cached
  image — measured at ~23 ms for 3,826 files, and growing with the user's
  collection. That ran on `CardsLive`'s mount path (twice: dead render
  plus connected mount) and made /cards the slowest page in the app.

  `Scry2.Cards.ImageCache` is the *only* writer to the cache directory:
  it downloads files into it and clears it on a version turnover. So the
  cache can keep its own running total and hand it out in constant time,
  and the figure stays exact as the user browses — unlike a snapshot
  cached until some invalidation event, which would silently drift with
  every image downloaded.

  Note the contrast with `Scry2.Cards`' card-table byte sizes, which are
  cached in `:persistent_term` until an import invalidates them. That is
  correct *there* because those tables only change on import. It would be
  wrong here.

  ## Directory identity

  A total describes one directory. Every mutation names the directory it
  applies to and is ignored if it does not match, so a write aimed at some
  other cache directory — a test's `tmp_dir`, say — cannot move the total
  the application is reporting.

  ## Out-of-band changes

  Deleting the cache directory by hand desyncs the total until the next
  restart, when it is scanned afresh. The directory is `ImageCache`'s
  private storage; mutating it from outside is outside the contract.
  """

  @enforce_keys [:dir, :count, :bytes]
  defstruct [:dir, :count, :bytes]

  @type t :: %__MODULE__{
          dir: String.t(),
          count: non_neg_integer(),
          bytes: non_neg_integer()
        }

  @extension ".jpg"

  @doc "A zeroed total for `dir`, before it has been scanned."
  @spec empty(String.t()) :: t()
  def empty(dir), do: %__MODULE__{dir: dir, count: 0, bytes: 0}

  @doc """
  Reads `dir` and totals the cached images in it. The authoritative
  measurement, run once at startup; a missing directory totals zero.
  """
  @spec scan(String.t()) :: t()
  def scan(dir) do
    Enum.reduce(image_files(dir), empty(dir), fn path, usage ->
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} ->
          %{usage | count: usage.count + 1, bytes: usage.bytes + size}

        _ ->
          usage
      end
    end)
  end

  @doc """
  The cached image files in `dir`, as full paths.

  The single definition of what counts as a cache image — the cache's
  `cache-version` marker lives in the same directory and is not one.
  """
  @spec image_files(String.t()) :: [String.t()]
  def image_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, @extension))
        |> Enum.map(&Path.join(dir, &1))

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Adds newly downloaded files to the total. Ignored unless `dir` is the
  directory this total describes.
  """
  @spec add(t(), String.t(), non_neg_integer(), non_neg_integer()) :: t()
  def add(%__MODULE__{dir: dir} = usage, dir, count, bytes) do
    %{usage | count: usage.count + count, bytes: usage.bytes + bytes}
  end

  def add(%__MODULE__{} = usage, _other_dir, _count, _bytes), do: usage

  @doc """
  Zeroes the total after the cache directory has been emptied. Ignored
  unless `dir` is the directory this total describes.
  """
  @spec reset(t(), String.t()) :: t()
  def reset(%__MODULE__{dir: dir} = usage, dir), do: %{usage | count: 0, bytes: 0}
  def reset(%__MODULE__{} = usage, _other_dir), do: usage
end
