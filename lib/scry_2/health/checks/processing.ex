defmodule Scry2.Health.Checks.Processing do
  @moduledoc """
  Pure event-processing checks.

  These detect "the pipeline is moving" health:

    * Are raw events translating without errors?
    * Are projectors caught up to the domain event log?
    * Are we seeing unknown MTGA event types that have no handler?

  The facade collects the inputs (error counts, projector snapshot,
  by-type counts) and passes them to these functions.
  """

  alias Scry2.Health.Check

  @warn_error_count 10
  @error_error_count 100

  @doc """
  Reports the raw-event processing error count.

  Elevated error counts typically mean either a translator regression
  (the anti-corruption layer is mishandling a new event shape) or a
  DB-level failure during ingestion.
  """
  @spec low_error_count(non_neg_integer()) :: Check.t()
  def low_error_count(0) do
    Check.new(
      id: :low_error_count,
      category: :processing,
      name: "No processing errors",
      status: :ok,
      summary: "No errors recorded"
    )
  end

  def low_error_count(count) when is_integer(count) and count > 0 do
    status =
      cond do
        count >= @error_error_count -> :error
        count >= @warn_error_count -> :warning
        true -> :warning
      end

    Check.new(
      id: :low_error_count,
      category: :processing,
      name: "No processing errors",
      status: status,
      summary: "#{count} raw events failed processing",
      detail: "See Operations → Processing errors for the full list."
    )
  end

  @doc """
  Reports whether all projectors have caught up to the domain event log.

  Takes a list of projector status maps matching the shape returned by
  `Scry2.Events.ProjectorRegistry.status_all/0`:

      [%{name: "matches", watermark: 1234, max_event_id: 1234, caught_up: true, ...}, ...]

  `:pending` is returned when there are no projectors at all — which
  only happens in tests where the event-sourced pipeline isn't started.
  """
  @spec projectors_caught_up([map()]) :: Check.t()
  def projectors_caught_up([]) do
    Check.new(
      id: :projectors_caught_up,
      category: :processing,
      name: "Projectors caught up",
      status: :pending,
      summary: "No projectors registered"
    )
  end

  def projectors_caught_up(projectors) when is_list(projectors) do
    lagging = Enum.reject(projectors, & &1.caught_up)

    case lagging do
      [] ->
        Check.new(
          id: :projectors_caught_up,
          category: :processing,
          name: "Projectors caught up",
          status: :ok,
          summary: "#{length(projectors)} projectors up to date"
        )

      lagging ->
        names = lagging |> Enum.map(& &1.name) |> Enum.join(", ")

        total_lag =
          lagging
          |> Enum.map(fn p -> max(p.max_event_id - p.watermark, 0) end)
          |> Enum.sum()

        Check.new(
          id: :projectors_caught_up,
          category: :processing,
          name: "Projectors caught up",
          status: :warning,
          summary: "#{length(lagging)} projectors behind (#{total_lag} events lag)",
          detail: "Lagging projectors: #{names}"
        )
    end
  end

  @doc """
  Reports the count of raw events whose type is unknown to the
  anti-corruption layer (`IdentifyDomainEvents`).

  A small backlog is normal (MTGA adds new event types periodically).
  A large one means a handler is missing.

  Inputs:
    * `events_by_type` — full count map from `MtgaLogIngestion.count_by_type/0`
    * `known_types` — `MapSet` from `IdentifyDomainEvents.known_event_types/0`
  """
  @spec no_unrecognized_backlog(%{String.t() => non_neg_integer()}, MapSet.t()) :: Check.t()
  def no_unrecognized_backlog(events_by_type, known_types)
      when is_map(events_by_type) do
    unrecognized =
      events_by_type
      |> Enum.reject(fn {type, _count} -> MapSet.member?(known_types, type) end)

    case unrecognized do
      [] ->
        Check.new(
          id: :no_unrecognized_backlog,
          category: :processing,
          name: "All event types recognized",
          status: :ok,
          summary: "Every persisted event type has a handler"
        )

      unknown ->
        count = unknown |> Enum.map(fn {_type, count} -> count end) |> Enum.sum()
        distinct = length(unknown)

        status = if count >= @warn_error_count, do: :warning, else: :ok

        Check.new(
          id: :no_unrecognized_backlog,
          category: :processing,
          name: "All event types recognized",
          status: status,
          summary: "#{distinct} unrecognized event type(s), #{count} events",
          detail:
            "See Operations → Unrecognized event types. New MTGA events show up " <>
              "here first and usually need a handler in IdentifyDomainEvents."
        )
    end
  end
end
