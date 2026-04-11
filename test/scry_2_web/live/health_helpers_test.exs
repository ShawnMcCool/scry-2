defmodule Scry2Web.HealthHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2.Health.Check
  alias Scry2.Health.Report
  alias Scry2Web.HealthHelpers

  describe "status_class/1" do
    test "maps statuses to daisyUI alert variants" do
      assert HealthHelpers.status_class(:ok) == "alert-success"
      assert HealthHelpers.status_class(:warning) == "alert-warning"
      assert HealthHelpers.status_class(:error) == "alert-error"
      assert HealthHelpers.status_class(:pending) == "alert-info"
    end
  end

  describe "status_icon/1" do
    test "maps statuses to hero icon names" do
      assert HealthHelpers.status_icon(:ok) == "hero-check-circle"
      assert HealthHelpers.status_icon(:warning) == "hero-exclamation-triangle"
      assert HealthHelpers.status_icon(:error) == "hero-x-circle"
      assert HealthHelpers.status_icon(:pending) == "hero-clock"
    end
  end

  describe "category_label/1" do
    test "maps every category to a human label" do
      assert HealthHelpers.category_label(:ingestion) == "Ingestion"
      assert HealthHelpers.category_label(:card_data) == "Card Data"
      assert HealthHelpers.category_label(:processing) == "Processing"
      assert HealthHelpers.category_label(:config) == "Configuration"
    end
  end

  describe "category_order/0" do
    test "returns the canonical display order" do
      assert HealthHelpers.category_order() == [:ingestion, :card_data, :processing, :config]
    end
  end

  describe "ordered_categories/1" do
    test "returns categories in canonical order, skipping empty ones" do
      check_a =
        Check.new(id: :a, category: :processing, name: "A", status: :ok)

      check_b =
        Check.new(id: :b, category: :ingestion, name: "B", status: :error)

      report = Report.new([check_a, check_b])

      assert [{:ingestion, [^check_b]}, {:processing, [^check_a]}] =
               HealthHelpers.ordered_categories(report)
    end
  end

  describe "overall_message/1 and overall_class/1" do
    test "messages match severity" do
      assert HealthHelpers.overall_message(:ok) == "All systems healthy"
      assert HealthHelpers.overall_message(:warning) == "Some checks need attention"
      assert HealthHelpers.overall_message(:error) == "Some checks are failing"
    end

    test "classes match severity" do
      assert HealthHelpers.overall_class(:ok) == "alert-success"
      assert HealthHelpers.overall_class(:warning) == "alert-warning"
      assert HealthHelpers.overall_class(:error) == "alert-error"
    end
  end
end
