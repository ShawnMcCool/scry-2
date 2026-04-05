defmodule Scry2.MtgaLogs.EventRecord do
  @moduledoc """
  Ecto schema for persisted raw log events (table `mtga_logs_events`).

  Named `EventRecord` to distinguish from `Scry2.MtgaLogs.Event`, which is
  the in-memory struct produced by `Scry2.MtgaLogs.EventParser`. Every
  parsed event lands here BEFORE any downstream context sees it — see
  ADR-015 (raw event replay).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "mtga_logs_events" do
    field :event_type, :string
    field :mtga_timestamp, :utc_datetime
    field :file_offset, :integer
    field :source_file, :string
    field :raw_json, :string
    field :processed, :boolean, default: false
    field :processed_at, :utc_datetime
    field :processing_error, :string
    field :inserted_at, :utc_datetime
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :event_type,
      :mtga_timestamp,
      :file_offset,
      :source_file,
      :raw_json,
      :processed,
      :processed_at,
      :processing_error,
      :inserted_at
    ])
    |> validate_required([:event_type, :file_offset, :source_file, :raw_json])
    |> ensure_inserted_at()
  end

  defp ensure_inserted_at(changeset) do
    case get_field(changeset, :inserted_at) do
      nil -> put_change(changeset, :inserted_at, DateTime.utc_now(:second))
      _ -> changeset
    end
  end
end
