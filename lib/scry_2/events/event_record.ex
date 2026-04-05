defmodule Scry2.Events.EventRecord do
  @moduledoc """
  Ecto schema for the append-only domain event log (table `domain_events`).

  This is the **persisted** form of a domain event. Distinguish from the
  **struct** form under `Scry2.Events.*` (e.g. `%Scry2.Events.MatchCreated{}`)
  — the struct is what the translator produces and what projectors consume;
  the schema is how we serialize it to disk.

  The roundtrip is:

      struct  --Scry2.Events.append!/2-->  EventRecord row  --Scry2.Events.get!/1-->  struct

  See `Scry2.Events` for the public API, ADR-017 for why event sourcing,
  and ADR-018 for the anti-corruption translator that produces these.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "domain_events" do
    # Stable slug like "match_created" — NOT a module name, so renames
    # don't invalidate historical records.
    field :event_type, :string

    # The domain event struct's fields, serialized as JSON. Ecto's :map
    # type handles encode/decode via Jason.
    field :payload, :map

    # Which raw MTGA log event produced this domain event. Soft reference
    # (no FK) — the raw event is kept for debugging only and its lifecycle
    # is independent of derived state (ADR-015).
    field :mtga_source_id, :integer

    # When this event happened in MTGA time. Nullable.
    field :mtga_timestamp, :utc_datetime

    field :inserted_at, :utc_datetime
  end

  @doc """
  Changeset for inserting a new domain event. `payload` is validated as
  a map (Ecto `:map` type), `event_type` is required, `inserted_at` is
  auto-set to `DateTime.utc_now/1` in second precision if not provided.

  Domain events are **append-only** — there is no update changeset, no
  delete path. Any mutation would violate the event sourcing invariant
  (ADR-017).
  """
  def changeset(record, attrs) do
    record
    |> cast(attrs, [:event_type, :payload, :mtga_source_id, :mtga_timestamp, :inserted_at])
    |> validate_required([:event_type, :payload])
    |> ensure_inserted_at()
  end

  defp ensure_inserted_at(changeset) do
    case get_field(changeset, :inserted_at) do
      nil -> put_change(changeset, :inserted_at, DateTime.utc_now(:second))
      _ -> changeset
    end
  end
end
