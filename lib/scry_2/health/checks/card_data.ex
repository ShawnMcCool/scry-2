defmodule Scry2.Health.Checks.CardData do
  @moduledoc """
  Pure card-reference-data checks.

  Scry2's card pipeline is:

  1. **MTGA client SQLite** (`cards_mtga_cards`) — canonical Arena card list,
     sourced from the user's local game install.
  2. **Scryfall bulk data** (`cards_scryfall_cards`) — oracle metadata,
     image URIs, coverage of rotated cards no longer in MTGA.
  3. **Synthesised read model** (`cards_cards`) — built from the two sources
     by `Scry2.Cards.Synthesize`. This is what queries actually hit.

  Either of the three missing leaves downstream projections unable to resolve
  card details for event payloads. Stale (>7 days) usually just means the
  daily/weekly cron hasn't run yet — recoverable by enqueuing the worker
  manually.

  Inputs are passed in; the facade collects them from `Cards`.
  """

  alias Scry2.Health.Check

  @stale_threshold_days 7

  @doc """
  Reports whether the synthesised `cards_cards` read model has been built.
  """
  @spec synthesized_present(non_neg_integer()) :: Check.t()
  def synthesized_present(0) do
    Check.new(
      id: :synthesized_present,
      category: :card_data,
      name: "Card data synthesised",
      status: :error,
      summary: "No cards in the synthesised model",
      detail:
        "Card names, rarities and types come from synthesising MTGA + Scryfall " <>
          "data. The synthesis runs automatically on first boot — if this check is " <>
          "still red shortly after launch, the upstream imports may still be running. " <>
          "Check the console drawer for import logs.",
      fix: :enqueue_synthesis
    )
  end

  def synthesized_present(count) when is_integer(count) and count > 0 do
    Check.new(
      id: :synthesized_present,
      category: :card_data,
      name: "Card data synthesised",
      status: :ok,
      summary: "#{count} cards in database"
    )
  end

  @doc """
  Reports whether the synthesised card data is fresh.

  Staleness threshold is 7 days — matches the assumption that the daily
  synthesis cron will refresh the data, and weekly means it ran at least
  once in the expected window. `nil` is treated as missing (handled by
  `synthesized_present/1`, but this function still emits a warning).
  """
  @spec synthesized_fresh(DateTime.t() | nil) :: Check.t()
  @spec synthesized_fresh(DateTime.t() | nil, DateTime.t()) :: Check.t()
  def synthesized_fresh(updated_at, now \\ DateTime.utc_now())

  def synthesized_fresh(nil, _now) do
    Check.new(
      id: :synthesized_fresh,
      category: :card_data,
      name: "Card data fresh",
      status: :warning,
      summary: "Synthesis timestamp unknown",
      fix: :enqueue_synthesis
    )
  end

  def synthesized_fresh(%DateTime{} = updated_at, %DateTime{} = now) do
    age_days = DateTime.diff(now, updated_at, :day)

    cond do
      age_days <= @stale_threshold_days ->
        Check.new(
          id: :synthesized_fresh,
          category: :card_data,
          name: "Card data fresh",
          status: :ok,
          summary: "Updated #{age_days} day(s) ago"
        )

      true ->
        Check.new(
          id: :synthesized_fresh,
          category: :card_data,
          name: "Card data fresh",
          status: :warning,
          summary: "Last updated #{age_days} days ago (older than #{@stale_threshold_days})",
          detail:
            "The daily synthesis cron may not have run. Triggering a manual " <>
              "refresh usually fixes this.",
          fix: :enqueue_synthesis
        )
    end
  end

  @doc """
  Reports whether Scryfall bulk data is present.
  """
  @spec scryfall_present(non_neg_integer()) :: Check.t()
  def scryfall_present(0) do
    Check.new(
      id: :scryfall_present,
      category: :card_data,
      name: "Scryfall data imported",
      status: :error,
      summary: "No Scryfall bulk data in database",
      detail:
        "Scryfall provides oracle text, image URIs, and coverage of rotated " <>
          "cards no longer in the local MTGA database.",
      fix: :enqueue_scryfall
    )
  end

  def scryfall_present(count) when is_integer(count) and count > 0 do
    Check.new(
      id: :scryfall_present,
      category: :card_data,
      name: "Scryfall data imported",
      status: :ok,
      summary: "#{count} Scryfall cards in database"
    )
  end

  @doc """
  Reports whether Scryfall data is fresh.

  Same 7-day staleness threshold as the synthesis check, since the cron
  runs weekly on Sundays.
  """
  @spec scryfall_fresh(DateTime.t() | nil) :: Check.t()
  @spec scryfall_fresh(DateTime.t() | nil, DateTime.t()) :: Check.t()
  def scryfall_fresh(updated_at, now \\ DateTime.utc_now())

  def scryfall_fresh(nil, _now) do
    Check.new(
      id: :scryfall_fresh,
      category: :card_data,
      name: "Scryfall data fresh",
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
          name: "Scryfall data fresh",
          status: :ok,
          summary: "Updated #{age_days} day(s) ago"
        )

      true ->
        Check.new(
          id: :scryfall_fresh,
          category: :card_data,
          name: "Scryfall data fresh",
          status: :warning,
          summary: "Last updated #{age_days} days ago (older than #{@stale_threshold_days})",
          fix: :enqueue_scryfall
        )
    end
  end
end
