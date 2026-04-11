defmodule Scry2.Health.Checks.CardData do
  @moduledoc """
  Pure card-reference-data checks.

  Scry2 imports two independent reference sources:

    1. **17lands cards.csv** — the primary card data (name, rarity, colors,
       type, mana value). Rows live in `cards_cards`.
    2. **Scryfall bulk data** — the arena_id backfill source used to attach
       MTGA's 5-digit identifier to 17lands rows. Rows live in `cards_scryfall_cards`.

  Either one missing leaves downstream projections unable to resolve card
  names for event payloads. Both stale (>7 days) usually just means the
  daily cron hasn't run yet — recoverable by enqueuing the worker manually.

  Inputs are passed in; the facade collects them from `Cards`.
  """

  alias Scry2.Health.Check

  @stale_threshold_days 7

  @doc """
  Reports whether 17lands `cards_cards` has been imported at all.
  """
  @spec lands17_present(non_neg_integer()) :: Check.t()
  def lands17_present(0) do
    Check.new(
      id: :lands17_present,
      category: :card_data,
      name: "17lands card data imported",
      status: :error,
      summary: "No 17lands card data in database",
      detail:
        "Card names, rarities and types come from 17lands. The import runs " <>
          "automatically on first boot — if this check is still red shortly after " <>
          "launch, the import may be retrying. Check the console drawer for import logs.",
      fix: :enqueue_lands17
    )
  end

  def lands17_present(count) when is_integer(count) and count > 0 do
    Check.new(
      id: :lands17_present,
      category: :card_data,
      name: "17lands card data imported",
      status: :ok,
      summary: "#{count} cards in database"
    )
  end

  @doc """
  Reports whether 17lands data is fresh.

  Staleness threshold is 7 days — matches the assumption that the daily
  cron will refresh the data, and weekly means it ran at least once in
  the expected window. `nil` is treated as missing (handled by
  `lands17_present/1`, but this function still emits a warning).
  """
  @spec lands17_fresh(DateTime.t() | nil) :: Check.t()
  @spec lands17_fresh(DateTime.t() | nil, DateTime.t()) :: Check.t()
  def lands17_fresh(updated_at, now \\ DateTime.utc_now())

  def lands17_fresh(nil, _now) do
    Check.new(
      id: :lands17_fresh,
      category: :card_data,
      name: "17lands card data fresh",
      status: :warning,
      summary: "Import timestamp unknown",
      fix: :enqueue_lands17
    )
  end

  def lands17_fresh(%DateTime{} = updated_at, %DateTime{} = now) do
    age_days = DateTime.diff(now, updated_at, :day)

    cond do
      age_days <= @stale_threshold_days ->
        Check.new(
          id: :lands17_fresh,
          category: :card_data,
          name: "17lands card data fresh",
          status: :ok,
          summary: "Updated #{age_days} day(s) ago"
        )

      true ->
        Check.new(
          id: :lands17_fresh,
          category: :card_data,
          name: "17lands card data fresh",
          status: :warning,
          summary: "Last updated #{age_days} days ago (older than #{@stale_threshold_days})",
          detail:
            "The daily refresh cron may not have run. Triggering a manual import " <>
              "usually fixes this.",
          fix: :enqueue_lands17
        )
    end
  end

  @doc """
  Reports whether Scryfall backfill data is present.
  """
  @spec scryfall_present(non_neg_integer()) :: Check.t()
  def scryfall_present(0) do
    Check.new(
      id: :scryfall_present,
      category: :card_data,
      name: "Scryfall backfill imported",
      status: :error,
      summary: "No Scryfall bulk data in database",
      detail:
        "Scryfall bulk data is used to attach MTGA arena_ids to 17lands rows. " <>
          "Without it, event payloads can't fully resolve card details.",
      fix: :enqueue_scryfall
    )
  end

  def scryfall_present(count) when is_integer(count) and count > 0 do
    Check.new(
      id: :scryfall_present,
      category: :card_data,
      name: "Scryfall backfill imported",
      status: :ok,
      summary: "#{count} Scryfall cards in database"
    )
  end

  @doc """
  Reports whether Scryfall data is fresh.

  Same 7-day staleness threshold as the 17lands check, since the cron
  runs weekly on Sundays.
  """
  @spec scryfall_fresh(DateTime.t() | nil) :: Check.t()
  @spec scryfall_fresh(DateTime.t() | nil, DateTime.t()) :: Check.t()
  def scryfall_fresh(updated_at, now \\ DateTime.utc_now())

  def scryfall_fresh(nil, _now) do
    Check.new(
      id: :scryfall_fresh,
      category: :card_data,
      name: "Scryfall backfill fresh",
      status: :warning,
      summary: "Import timestamp unknown",
      fix: :enqueue_scryfall
    )
  end

  def scryfall_fresh(%DateTime{} = updated_at, %DateTime{} = now) do
    age_days = DateTime.diff(now, updated_at, :day)

    cond do
      age_days <= @stale_threshold_days ->
        Check.new(
          id: :scryfall_fresh,
          category: :card_data,
          name: "Scryfall backfill fresh",
          status: :ok,
          summary: "Updated #{age_days} day(s) ago"
        )

      true ->
        Check.new(
          id: :scryfall_fresh,
          category: :card_data,
          name: "Scryfall backfill fresh",
          status: :warning,
          summary: "Last updated #{age_days} days ago (older than #{@stale_threshold_days})",
          fix: :enqueue_scryfall
        )
    end
  end
end
