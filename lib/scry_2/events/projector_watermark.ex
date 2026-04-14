defmodule Scry2.Events.ProjectorWatermark do
  @moduledoc """
  Tracks the last domain event each projector has successfully processed.

  One row per projector. The `last_event_id` column references the
  auto-increment `id` in `domain_events` — it's a cursor, not a foreign key.
  Watermarks enable resumable replay, progress visibility, and per-projector
  lag measurement.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "projector_watermarks" do
    field :projector_name, :string
    field :last_event_id, :integer, default: 0
    field :content_hash, :string
    field :updated_at, :utc_datetime
  end

  def changeset(watermark, attrs) do
    watermark
    |> cast(attrs, [:projector_name, :last_event_id, :content_hash, :updated_at])
    |> validate_required([:projector_name, :last_event_id])
    |> unique_constraint(:projector_name)
  end
end
