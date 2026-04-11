defmodule Scry2Web.HealthHelpers do
  @moduledoc """
  Pure helpers for `Scry2Web.HealthLive` (ADR-013).

  Converts `%Scry2.Health.Check{}` status atoms into UI styling strings,
  groups checks by category for rendering, and produces the banner
  classes/messages for the overall report state.
  """

  alias Scry2.Health.Check
  alias Scry2.Health.Report

  @doc """
  Returns the daisyUI alert variant class for a check status.
  """
  @spec status_class(Check.status()) :: String.t()
  def status_class(:ok), do: "alert-soft alert-success"
  def status_class(:warning), do: "alert-soft alert-warning"
  def status_class(:error), do: "alert-soft alert-error"
  def status_class(:pending), do: "alert-soft alert-info"

  @doc """
  Returns the HeroIcon name for a check status.
  """
  @spec status_icon(Check.status()) :: String.t()
  def status_icon(:ok), do: "hero-check-circle"
  def status_icon(:warning), do: "hero-exclamation-triangle"
  def status_icon(:error), do: "hero-x-circle"
  def status_icon(:pending), do: "hero-clock"

  @doc """
  Returns the badge variant class for a status.
  """
  @spec status_badge_class(Check.status()) :: String.t()
  def status_badge_class(:ok), do: "badge-soft badge-success"
  def status_badge_class(:warning), do: "badge-soft badge-warning"
  def status_badge_class(:error), do: "badge-soft badge-error"
  def status_badge_class(:pending), do: "badge-ghost"

  @doc """
  Human-readable label for a check status.
  """
  @spec status_label(Check.status()) :: String.t()
  def status_label(:ok), do: "OK"
  def status_label(:warning), do: "Warning"
  def status_label(:error), do: "Failed"
  def status_label(:pending), do: "Pending"

  @doc """
  Human-readable label for a check category.
  """
  @spec category_label(Check.category()) :: String.t()
  def category_label(:ingestion), do: "Ingestion"
  def category_label(:card_data), do: "Card Data"
  def category_label(:processing), do: "Processing"
  def category_label(:config), do: "Configuration"

  @doc """
  Returns the canonical category display order.
  """
  @spec category_order() :: [Check.category()]
  def category_order, do: [:ingestion, :card_data, :processing, :config]

  @doc """
  Returns categories from a report in canonical order, omitting any
  with no checks. Each returned entry is `{category, [checks]}`.
  """
  @spec ordered_categories(Report.t()) :: [{Check.category(), [Check.t()]}]
  def ordered_categories(%Report{} = report) do
    grouped = Report.by_category(report)

    category_order()
    |> Enum.flat_map(fn category ->
      case Map.get(grouped, category) do
        nil -> []
        checks -> [{category, checks}]
      end
    end)
  end

  @doc """
  Returns the banner text for an overall report status.
  """
  @spec overall_message(:ok | :warning | :error) :: String.t()
  def overall_message(:ok), do: "All systems healthy"
  def overall_message(:warning), do: "Some checks need attention"
  def overall_message(:error), do: "Some checks are failing"

  @doc """
  Returns the alert class for the top-of-page overall banner.
  """
  @spec overall_class(:ok | :warning | :error) :: String.t()
  def overall_class(:ok), do: "alert-soft alert-success"
  def overall_class(:warning), do: "alert-soft alert-warning"
  def overall_class(:error), do: "alert-soft alert-error"
end
