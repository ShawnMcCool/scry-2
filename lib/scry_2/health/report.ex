defmodule Scry2.Health.Report do
  @moduledoc """
  Aggregated output of a full health run.

  A report is a snapshot of every check result plus a derived
  overall status — the worst status present across all checks.

  ## Fields

    * `checks` — the individual `%Check{}` results, in the order they ran
    * `overall` — `:ok | :warning | :error` (derived from `worst_status/1`)
    * `generated_at` — timestamp of the run
  """

  alias Scry2.Health.Check

  @enforce_keys [:checks, :overall, :generated_at]
  defstruct [:checks, :overall, :generated_at]

  @type overall :: :ok | :warning | :error

  @type t :: %__MODULE__{
          checks: [Check.t()],
          overall: overall(),
          generated_at: DateTime.t()
        }

  @status_rank %{pending: 0, ok: 1, warning: 2, error: 3}

  @doc """
  Builds a report from a list of checks. Computes `overall` as the
  worst status present; an empty list resolves to `:ok`.
  """
  @spec new([Check.t()]) :: t()
  def new(checks) when is_list(checks) do
    %__MODULE__{
      checks: checks,
      overall: worst_status(checks),
      generated_at: DateTime.utc_now()
    }
  end

  @doc """
  Returns the worst status found in a list of checks.

  Ordering (worst → best): `:error > :warning > :ok > :pending`.
  An empty list returns `:ok`. `:pending` is treated as "not yet
  reportable"; it never outranks `:ok`.
  """
  @spec worst_status([Check.t()]) :: overall()
  def worst_status([]), do: :ok

  def worst_status(checks) when is_list(checks) do
    checks
    |> Enum.map(& &1.status)
    |> Enum.max_by(&Map.fetch!(@status_rank, &1), fn -> :ok end)
    |> normalize_overall()
  end

  # :pending is not an overall status — we report :ok until a real result arrives.
  defp normalize_overall(:pending), do: :ok
  defp normalize_overall(other), do: other

  @doc """
  Groups checks by category. Returns a map of
  `category => [Check.t()]`, preserving input order within each group.
  """
  @spec by_category(t() | [Check.t()]) :: %{Check.category() => [Check.t()]}
  def by_category(%__MODULE__{checks: checks}), do: by_category(checks)

  def by_category(checks) when is_list(checks) do
    Enum.group_by(checks, & &1.category)
  end
end
