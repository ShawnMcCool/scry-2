defmodule Scry2.Collection do
  @moduledoc """
  Public facade for the memory-read card collection subsystem (ADR 034).

  Owns:
    * `collection_snapshots` table (append-only capture log).
    * The `collection.reader_enabled` settings flag.

  Communicates:
    * Subscribes — none (divergence checks read `mtga_logs_*` schemas
      directly when they land).
    * Broadcasts — `Scry2.Topics.collection_snapshots/0`.

  The actual read lives in `Scry2.Collection.Reader`; the Oban worker
  `Scry2.Collection.RefreshJob` drives scheduled and manual refreshes.
  """

  alias Scry2.Collection.RefreshJob
  alias Scry2.Collection.Snapshot
  alias Scry2.Repo
  alias Scry2.Settings
  alias Scry2.Topics
  alias Scry2.Version

  import Ecto.Query

  @reader_enabled_key "collection.reader_enabled"

  @doc "Returns the most recent collection snapshot, or `nil`."
  @spec current() :: Snapshot.t() | nil
  def current do
    Snapshot
    |> order_by([s], desc: s.snapshot_ts)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns snapshots newest-first.

  Options:
    * `:limit` — cap on rows returned (default 50).
  """
  @spec list_snapshots(keyword()) :: [Snapshot.t()]
  def list_snapshots(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Snapshot
    |> order_by([s], desc: s.snapshot_ts)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Returns true if the memory reader is user-enabled."
  @spec reader_enabled?() :: boolean()
  def reader_enabled? do
    Settings.get(@reader_enabled_key, false) == true
  end

  @doc "Enables the memory reader (user has signed the consent modal)."
  @spec enable_reader!() :: :ok
  def enable_reader! do
    Settings.put!(@reader_enabled_key, true)
    :ok
  end

  @doc "Disables the memory reader — kill switch (ADR 034)."
  @spec disable_reader!() :: :ok
  def disable_reader! do
    Settings.put!(@reader_enabled_key, false)
    :ok
  end

  @doc """
  Enqueues a `RefreshJob`. `trigger` classifies the origin so the UI
  can distinguish manual vs scheduled runs in the snapshot log.
  """
  @spec refresh(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def refresh(opts \\ []) do
    trigger = Keyword.get(opts, :trigger, "manual")
    %{"trigger" => to_string(trigger)} |> RefreshJob.new() |> Oban.insert()
  end

  @doc """
  Persists a read result as a `Snapshot` row, broadcasting on
  `Scry2.Topics.collection_snapshots/0`.

  Accepts the map returned by `Scry2.Collection.Reader.read/1`.
  """
  @spec save_snapshot(%{
          :entries => [Snapshot.entry()],
          :card_count => non_neg_integer(),
          :total_copies => non_neg_integer(),
          :reader_confidence => String.t(),
          optional(atom()) => term()
        }) :: {:ok, Snapshot.t()} | {:error, Ecto.Changeset.t()}
  def save_snapshot(result) do
    attrs =
      %{
        snapshot_ts: DateTime.utc_now(),
        reader_version: Version.current(),
        reader_confidence: result.reader_confidence,
        card_count: result.card_count,
        total_copies: result.total_copies,
        entries: result.entries
      }
      |> Map.merge(walker_fields(result))

    with {:ok, snapshot} <-
           %Snapshot{}
           |> Snapshot.changeset(attrs)
           |> Repo.insert() do
      Topics.broadcast(Topics.collection_snapshots(), {:snapshot_saved, snapshot})
      {:ok, snapshot}
    end
  end

  defp walker_fields(result) do
    result
    |> Map.take([
      :mtga_build_hint,
      :wildcards_common,
      :wildcards_uncommon,
      :wildcards_rare,
      :wildcards_mythic,
      :gold,
      :gems,
      :vault_progress
    ])
  end
end
