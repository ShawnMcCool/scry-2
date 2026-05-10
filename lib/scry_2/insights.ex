defmodule Scry2.Insights do
  @moduledoc """
  Public facade for the insights subsystem — patterns the app noticed in
  your play, computed from existing domain projections.

  Owns the `insights` table.

  ## Pipeline

      Domain projections (Matches, Drafts, Decks, Cards, Ranks, Economy, Crafts, Collection)
        → Insights.Detectors.* (pure functions returning nil | %Insight{})
          → Scry2.Workers.PeriodicallyComputeInsights (Oban cron + on-demand)
            → Insights.compute_all/0 (persists; supersedes prior active rows)
              → broadcasts insights:updates
                → Showcase.Homepage (selects tiles for render)

  Detectors return measurements, never narrative. The `:title_template`
  and `:body_template` keys on a persisted `%Insight{}` reference template
  strings rendered at display time with the persisted stats — only the
  numbers vary, the wording is fixed per detector type.

  ## Communicates

    * Reads — domain context public APIs only (no aliases across boundaries).
    * Broadcasts — `Scry2.Topics.insights_updates/0` after `compute_all/0`.
  """

  import Ecto.Query

  alias Scry2.Insights.{Detectors, Insight}
  alias Scry2.Repo
  alias Scry2.Topics

  @doc """
  Lists active (not superseded) insights for a surface, newest first.

  `surface` is an atom (`:home`, `:insights_browser`); the schema stores
  it as a string, so the conversion is done here.
  """
  @spec list_active(atom()) :: [Insight.t()]
  def list_active(surface) when is_atom(surface) do
    surface_str = Atom.to_string(surface)

    Insight
    |> where([i], i.surface == ^surface_str and is_nil(i.superseded_at))
    |> order_by([i], desc: i.computed_at, desc: i.id)
    |> Repo.all()
  end

  @doc "Fetches a single insight by id, or nil if not found."
  @spec get(integer()) :: Insight.t() | nil
  def get(id), do: Repo.get(Insight, id)

  @doc "Same as `get/1` but raises if not found."
  @spec get!(integer()) :: Insight.t()
  def get!(id), do: Repo.get!(Insight, id)

  @doc "Stamps `last_shown_at` and increments `shown_count` for novelty scoring."
  @spec mark_shown!(Insight.t()) :: Insight.t()
  def mark_shown!(%Insight{} = insight) do
    insight
    |> Insight.changeset(%{
      last_shown_at: DateTime.utc_now(),
      shown_count: insight.shown_count + 1
    })
    |> Repo.update!()
  end

  @doc "Total number of insight rows persisted (active + superseded)."
  @spec count() :: non_neg_integer()
  def count, do: Repo.aggregate(Insight, :count, :id)

  @doc """
  Runs every registered detector for the given surface and persists any
  returned insights. Prior active rows for the same `(detector, surface)`
  are stamped with `superseded_at` in the same transaction.

  Broadcasts `:insights_recomputed` on `Topics.insights_updates/0` after
  the pass completes, even when zero new insights were produced (consumers
  re-read the active set on every signal).

  Options:
    * `:surface` — atom, default `:home`.

  Returns `{:ok, %{computed: n}}`.
  """
  @spec compute_all(keyword()) :: {:ok, %{computed: non_neg_integer()}}
  def compute_all(opts \\ []) do
    surface = Keyword.get(opts, :surface, :home)
    detectors = Detectors.for_surface(surface)

    insights =
      detectors
      |> Enum.map(& &1.detect([]))
      |> Enum.reject(&is_nil/1)

    {:ok, _} = Repo.transaction(fn -> persist_pass(insights) end)
    Topics.broadcast(Topics.insights_updates(), :insights_recomputed)
    {:ok, %{computed: length(insights)}}
  end

  defp persist_pass(insights) do
    now = DateTime.utc_now()

    Enum.each(insights, fn %Insight{} = insight ->
      Insight
      |> where(
        [i],
        i.detector == ^insight.detector and
          i.surface == ^insight.surface and
          is_nil(i.superseded_at)
      )
      |> Repo.update_all(set: [superseded_at: now, updated_at: now])

      attrs =
        insight
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])

      %Insight{}
      |> Insight.changeset(attrs)
      |> Repo.insert!()
    end)
  end
end
