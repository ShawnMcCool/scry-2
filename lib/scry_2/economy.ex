defmodule Scry2.Economy do
  @moduledoc """
  Context module for economy tracking — event entry costs, prizes,
  inventory balances, and resource transactions.

  Owns tables: `economy_event_entries`, `economy_inventory_snapshots`,
  `economy_transactions`.

  PubSub role: broadcasts `"economy:updates"` after projection writes.
  """

  import Ecto.Query

  alias Scry2.Economy.{CardGrant, EventEntry, InventorySnapshot, Transaction}
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

    broadcast({:economy_updated, :event_entry})
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

      broadcast({:economy_updated, :event_entry})
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

    broadcast({:economy_updated, :inventory})
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

    broadcast({:economy_updated, :transaction})
    transaction
  end

  # ── Card grants ────────────────────────────────────────────────────

  @doc "Lists recent card grants, newest first."
  @spec list_card_grants(keyword()) :: [CardGrant.t()]
  def list_card_grants(opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 25)

    CardGrant
    |> order_by([g], desc: g.occurred_at)
    |> limit(^limit_count)
    |> Repo.all()
  end

  @doc "Inserts a card-grant batch."
  @spec insert_card_grant!(map()) :: CardGrant.t()
  def insert_card_grant!(attrs) do
    attrs = Map.new(attrs)
    cards = Map.get(attrs, :cards, [])

    full_attrs =
      attrs
      |> Map.put(:cards, CardGrant.wrap_cards(cards))
      |> Map.put_new(:card_count, length(cards))

    grant =
      %CardGrant{}
      |> CardGrant.changeset(full_attrs)
      |> Repo.insert!()

    broadcast({:economy_updated, :card_grant})
    grant
  end

  @memory_diff_source "MemoryDiff"
  @memory_diff_pack_open_source "MemoryDiff:PackOpen"

  @doc """
  Source code stamped on memory-diff-derived card grants. Stable —
  the UI's source-label table maps this to a player-friendly label.
  """
  @spec memory_diff_source() :: String.t()
  def memory_diff_source, do: @memory_diff_source

  @doc """
  Source code stamped on memory-diff grants that correlate with a
  booster-count decrease in the same diff window — the strong
  signal that the player opened a pack from inventory.
  """
  @spec memory_diff_pack_open_source() :: String.t()
  def memory_diff_pack_open_source, do: @memory_diff_pack_open_source

  @doc """
  Records memory-diff-derived card grants for one consecutive
  snapshot pair.

  Pure attribution lives in `Scry2.Economy.AttributeMemoryGrants`;
  this function persists its output as a single
  `economy_card_grants` row stamped with `source: "MemoryDiff"` and
  the snapshot pair's ids for traceability + idempotency.

  Idempotent: the unique partial index on `to_snapshot_id` (where
  `to_snapshot_id IS NOT NULL`) means re-running on the same pair
  upserts nothing new (`on_conflict: :nothing`).

  Returns `{:ok, %CardGrant{}}` on insert, `{:ok, nil}` if there
  was nothing to record or the row already exists.
  """
  @spec record_memory_grants_from_snapshot_pair(
          Scry2.Collection.Snapshot.t() | nil,
          Scry2.Collection.Snapshot.t(),
          MapSet.t(integer())
        ) :: {:ok, CardGrant.t() | nil}
  def record_memory_grants_from_snapshot_pair(
        prev,
        %Scry2.Collection.Snapshot{} = next,
        exclude \\ MapSet.new()
      ) do
    case Scry2.Economy.AttributeMemoryGrants.attribute(prev, next, exclude) do
      [] ->
        {:ok, nil}

      grant_rows ->
        persist_memory_grant(grant_rows, prev, next)
    end
  end

  defp persist_memory_grant(grant_rows, prev, next) do
    if Repo.exists?(from(g in CardGrant, where: g.to_snapshot_id == ^next.id)) do
      {:ok, nil}
    else
      stringified = Enum.map(grant_rows, &stringify_keys/1)
      dropped_collation_id = dropped_collation_id(prev, next)

      attrs = %{
        source: source_for_drop(dropped_collation_id),
        source_id: source_id_for_drop(dropped_collation_id),
        cards: CardGrant.wrap_cards(stringified),
        card_count: length(stringified),
        occurred_at: next.snapshot_ts,
        from_snapshot_id: prev && prev.id,
        to_snapshot_id: next.id
      }

      grant =
        %CardGrant{}
        |> CardGrant.changeset(attrs)
        |> Repo.insert!()

      broadcast({:economy_updated, :card_grant})
      {:ok, grant}
    end
  end

  defp stringify_keys(row) when is_map(row) do
    Map.new(row, fn {k, v} -> {to_string(k), v} end)
  end

  # When a booster count dropped between snapshots, the cards in this
  # diff are highly likely to be a pack-open — label the row so the
  # UI can show "Pack opened" instead of the generic "Detected from
  # collection" label, and stamp source_id with the booster's set
  # code (resolved via Scry2.Cards.BoosterCollation). Pre-spike-18
  # snapshots have no booster data (`boosters_json` is nil) and fall
  # through to the generic label with nil source_id.
  defp source_for_drop(nil), do: @memory_diff_source
  defp source_for_drop(_collation_id), do: @memory_diff_pack_open_source

  defp source_id_for_drop(nil), do: nil

  defp source_id_for_drop(collation_id) when is_integer(collation_id),
    do: Scry2.Cards.BoosterCollation.lookup(collation_id)

  defp dropped_collation_id(nil, _next), do: nil

  defp dropped_collation_id(
         %Scry2.Collection.Snapshot{} = prev,
         %Scry2.Collection.Snapshot{} = next
       ) do
    prev_map = boosters_map(prev)
    next_map = boosters_map(next)

    Enum.find_value(prev_map, fn {collation_id, prev_count} ->
      next_count = Map.get(next_map, collation_id, 0)
      if prev_count > next_count, do: collation_id
    end)
  end

  defp boosters_map(%Scry2.Collection.Snapshot{boosters_json: json}) do
    json
    |> Scry2.Collection.Snapshot.decode_boosters()
    |> Map.new()
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

  defp broadcast(message) do
    unless Scry2.Events.SilentMode.silent?() do
      Topics.broadcast(Topics.economy_updates(), message)
    end
  end
end
