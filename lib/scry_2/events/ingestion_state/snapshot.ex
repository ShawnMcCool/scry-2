defmodule Scry2.Events.IngestionState.Snapshot do
  @moduledoc """
  Ecto schema for the singleton `ingestion_state` row.
  Serialization bridge between the `%IngestionState{}` struct and SQLite.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "ingestion_state" do
    field :version, :integer, default: 1
    field :last_raw_event_id, :integer, default: 0
    field :session, :map, default: %{}
    field :match, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:version, :last_raw_event_id, :session, :match])
    |> validate_required([:version, :last_raw_event_id])
  end
end
