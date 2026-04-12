defmodule Scry2.Economy do
  @moduledoc """
  Context module for economy tracking — event entry costs, prizes,
  inventory balances, and resource transactions.

  Owns tables: `economy_event_entries`, `economy_inventory_snapshots`,
  `economy_transactions`.

  PubSub role: broadcasts `"economy:updates"` after projection writes.
  """

  import Ecto.Query

  alias Scry2.Economy.{EventEntry, InventorySnapshot, Transaction}
  alias Scry2.Repo
  alias Scry2.Topics

  # ── Event entries ──────────────────────────────────────────────────

  @doc "Lists event entries, newest first."
  def list_event_entries(opts \\ []) do
    EventEntry
    |> maybe_filter_by_player(opts[:player_id])
    |> order_by([e], desc: e.joined_at)
    |> Repo.all()
  end

  @doc "Upserts an event entry by (player_id, event_name, joined_at)."
  def upsert_event_entry!(attrs) do
    attrs = Map.new(attrs)

    entry =
      %EventEntry{}
      |> EventEntry.changeset(attrs)
      |> Repo.insert!(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:player_id, :event_name, :joined_at]
      )

    Topics.broadcast(Topics.economy_updates(), {:economy_updated, :event_entry})
    entry
  end

  @doc """
  Enriches an existing event entry with reward data when the player
  claims prizes. Matches by player_id + event_name (most recent entry).
  """
  def enrich_with_reward!(player_id, event_name, reward_attrs) do
    entry =
      EventEntry
      |> where([e], e.event_name == ^event_name)
      |> maybe_filter_by_player(player_id)
      |> order_by([e], desc: e.joined_at)
      |> limit(1)
      |> Repo.one()

    if entry do
      entry
      |> EventEntry.changeset(Map.new(reward_attrs))
      |> Repo.update!()

      Topics.broadcast(Topics.economy_updates(), {:economy_updated, :event_entry})
    end
  end

  # ── Inventory snapshots ────────────────────────────────────────────

  @doc "Lists inventory snapshots ordered by occurred_at ascending."
  def list_inventory_snapshots(opts \\ []) do
    InventorySnapshot
    |> maybe_filter_by_player(opts[:player_id])
    |> order_by([s], asc: s.occurred_at)
    |> Repo.all()
  end

  @doc "Returns the most recent inventory snapshot."
  def latest_inventory(opts \\ []) do
    InventorySnapshot
    |> maybe_filter_by_player(opts[:player_id])
    |> order_by([s], desc: s.occurred_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Inserts an inventory snapshot."
  def insert_inventory_snapshot!(attrs) do
    snapshot =
      %InventorySnapshot{}
      |> InventorySnapshot.changeset(Map.new(attrs))
      |> Repo.insert!()

    Topics.broadcast(Topics.economy_updates(), {:economy_updated, :inventory})
    snapshot
  end

  # ── Transactions ───────────────────────────────────────────────────

  @doc "Lists transactions, newest first."
  def list_transactions(opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 100)

    Transaction
    |> maybe_filter_by_player(opts[:player_id])
    |> order_by([t], desc: t.occurred_at)
    |> limit(^limit_count)
    |> Repo.all()
  end

  @doc "Inserts a transaction."
  def insert_transaction!(attrs) do
    transaction =
      %Transaction{}
      |> Transaction.changeset(Map.new(attrs))
      |> Repo.insert!()

    Topics.broadcast(Topics.economy_updates(), {:economy_updated, :transaction})
    transaction
  end

  # ── Helpers ────────────────────────────────────────────────────────

  # ── Event name parsing ─────────────────────────────────────────────

  @event_type_map %{
    "Quickdraft" => "Quick Draft",
    "QuickDraft" => "Quick Draft",
    "PremierDraft" => "Premier Draft",
    "Premierdraft" => "Premier Draft",
    "TradDraft" => "Traditional Draft",
    "BotDraft" => "Bot Draft",
    "Sealed" => "Sealed",
    "CompDraft" => "Competitive Draft"
  }

  @doc """
  Splits a raw MTGA event name into `{event_type, set_code}`.

  Handles both underscore and space-separated formats:

      iex> Scry2.Economy.parse_event_name("QuickDraft_TMT_20260407")
      {"Quick Draft", "TMT"}

      iex> Scry2.Economy.parse_event_name("Sealed")
      {"Sealed", nil}
  """
  @spec parse_event_name(String.t() | nil) :: {String.t(), String.t() | nil}
  def parse_event_name(nil), do: {"—", nil}

  def parse_event_name(name) do
    parts = String.split(name, ~r/[_ ]/)

    event_type =
      Map.get(@event_type_map, hd(parts)) ||
        hd(parts)
        |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")

    set_code = Enum.find(tl(parts), &Regex.match?(~r/^[A-Za-z]{2,5}$/, &1))
    set_code = if set_code, do: String.upcase(set_code)

    {event_type, set_code}
  end

  defp maybe_filter_by_player(query, nil), do: query
  defp maybe_filter_by_player(query, player_id), do: where(query, [r], r.player_id == ^player_id)
end
