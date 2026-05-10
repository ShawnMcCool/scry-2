defmodule Scry2.Insights.Insight do
  @moduledoc """
  One materialized observation produced by a detector.

  Detectors return measurements (raw numbers, sample size, confidence). At
  display time, `:title_template` and `:body_template` reference template
  strings rendered with `:stats` and `:measurements`. The schema never
  stores generated narrative — wording is fixed per detector type and
  only the numbers vary.

  Lifecycle:

    * `computed_at` — when this row was created
    * `superseded_at` — set when a fresher run replaced it (nil = active)
    * `last_shown_at` / `shown_count` — novelty signals for the Showcase ranker
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type tier :: 1 | 2
  @type surface :: :home | :insights_browser

  @surfaces ~w(home insights_browser)

  @cast_fields [
    :detector,
    :surface,
    :tier,
    :title_template,
    :body_template,
    :stats,
    :measurements,
    :sample_size,
    :confidence,
    :computed_at,
    :superseded_at,
    :last_shown_at,
    :shown_count
  ]

  @required_fields [
    :detector,
    :surface,
    :tier,
    :title_template,
    :sample_size,
    :computed_at
  ]

  schema "insights" do
    field :detector, :string
    field :surface, :string
    field :tier, :integer
    field :title_template, :string
    field :body_template, :string
    field :stats, :map, default: %{}
    field :measurements, :map, default: %{}
    field :sample_size, :integer
    field :confidence, :float
    field :computed_at, :utc_datetime_usec
    field :superseded_at, :utc_datetime_usec
    field :last_shown_at, :utc_datetime_usec
    field :shown_count, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(insight, attrs) do
    insight
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:tier, [1, 2])
    |> validate_inclusion(:surface, @surfaces)
    |> validate_number(:sample_size, greater_than_or_equal_to: 0)
  end
end
